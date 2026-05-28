# nix/gitops/env/rook-operator.nix
#
# Rook-Ceph operator — Helm-templated at Nix build time.
#
# Provides:
#   - Rook operator Deployment (rook-ceph-operator)
#   - CSI provisioner Deployments for RBD + CephFS
#   - CSI plugin DaemonSets (rbdplugin, cephfsplugin) on every node
#   - All Ceph CRDs (CephCluster, CephBlockPool, CephFilesystem,
#     CephObjectStore, etc.) and admission webhooks
#
# The CephCluster CR + pools + RGW + CephFS land in rook-cluster.nix
# (task #6). Sync-wave -1 here so the operator + CRDs land before the
# cluster CR (sync-wave 0).
#
{ pkgs, lib, helm }:
let
  constants = import ../../constants.nix;

  operatorValuesYaml = ''
    # Trimmed values — chart defaults handle everything else.
    crds:
      enabled: true

    # CSI drivers for both RBD (block) and CephFS (shared FS).
    csi:
      enableRbdDriver: true
      enableCephfsDriver: true
      enableNFSDriver: false
      provisionerReplicas: 2

    # Monitoring scaffolding (Prometheus CR + ServiceMonitor). The
    # CRs are no-ops until Prometheus operator is in the cluster;
    # cheap to ship.
    monitoring:
      enabled: true

    # Operator resource requests sized for the lab (CP nodes are
    # 10 GiB / 4 vCPU per constants.nix vm).
    resources:
      limits:
        memory: 512Mi
      requests:
        cpu: 100m
        memory: 128Mi

    # Tolerate the control-plane taint, in case future kubelet config
    # adds it. Source repo's kubelet doesn't taint CPs today; this is
    # defensive — no-op when CPs are untainted.
    tolerations:
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Exists"
      effect: "NoSchedule"
  '';

  renderedOperator = helm.renderChart {
    name        = "rook-ceph-operator";
    releaseName = "rook-ceph";
    namespace   = constants.ceph.namespace;
    chart       = constants.helmCharts.rookCephOperator;
    values      = operatorValuesYaml;
  };
in
{
  manifests = [
    {
      name = "rook-operator/install.yaml";
      source = "${renderedOperator}/install.yaml";
    }
    {
      name = "rook-operator/values.yaml";
      content = operatorValuesYaml;
    }
    {
      name = "rook-operator/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: rook-operator
          namespace: argocd
          annotations:
            argocd.argoproj.io/sync-wave: "-1"
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/rook-operator
            directory:
              recurse: false
              exclude: '{application.yaml,values.yaml}'
          destination:
            server: https://kubernetes.default.svc
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
            syncOptions:
              - ServerSideApply=true
              - CreateNamespace=true
      '';
    }
  ];
}
