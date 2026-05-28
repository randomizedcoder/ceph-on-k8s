# nix/gitops/env/rook-cluster.nix
#
# CephCluster CR + pools + filesystem + object store, all Helm-templated
# from the rook-ceph-cluster chart at Nix build time.
#
# Topology (see docs/ceph-design.md for the full rationale):
#   - 3 MONs pinned to control planes (cp0/cp1/cp2)
#   - 2 MGRs with hostname anti-affinity
#   - 4 OSDs, one per node, PVC-based via storageClassDeviceSets on
#     the openebs-device StorageClass
#   - 3 MDS (1 active + 2 standby) for the single CephFilesystem
#   - 2 RGW instances for S3
#   - dashboard enabled; TLS termination at the Cilium Ingress (added
#     in task #7) using a cert from the in-cluster CA
#
# Pool replication is 3 across the `host` failure domain. Storage math
# (lab-only): 4 × 10 GiB raw → ~10 GiB usable after the ~20% near-full
# reserve and Bluestore's per-OSD metadata overhead.
#
# Task #7 adds the LoadBalancer Services + L2 announcement + Ingress
# + Certificate; this module ships the CephCluster + storage classes
# only.
#
{ pkgs, lib, helm }:
let
  constants = import ../../constants.nix;

  # Per-node `devices` entry for the CephCluster CR. The disk is
  # exposed as /dev/disk/by-id/virtio-ceph-osd-<hostname> by the
  # virtio-blk `serial=` set in nix/microvm.nix.
  #
  # Built with explicit indentation because Nix '' '' strings strip
  # common leading whitespace and would otherwise produce zero-indent
  # lines that break the rendered values.yaml's YAML structure.
  perNodeDevicesYaml = let
    indent = "        ";  # 8 spaces — under cephClusterSpec.storage.nodes
  in lib.concatMapStrings (n: let
    hostname = constants.getHostname n;
  in
    "${indent}- name: ${hostname}\n" +
    "${indent}  devices:\n" +
    "${indent}  - name: \"${constants.ceph.osd.devicePath}${hostname}\"\n"
  ) constants.nodeNames;

  clusterValuesYaml = ''
    # operatorNamespace must match the rook-operator chart's namespace.
    operatorNamespace: ${constants.ceph.namespace}
    clusterName: rook-ceph

    # ─── Toolbox: `rook-ceph-tools` Deployment for `ceph` CLI debugging ─
    toolbox:
      enabled: true
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"

    # See rook-operator.nix for the reason monitoring is off — same
    # ServiceMonitor CRD missing on this cluster.
    monitoring:
      enabled: false
      createPrometheusRules: false

    cephClusterSpec:
      mon:
        count: 3
        allowMultiplePerNode: false
      mgr:
        count: 2
        allowMultiplePerNode: false
        modules:
        - name: rook
          enabled: true
        - name: prometheus
          enabled: true
      dashboard:
        enabled: true
        # TLS is terminated at the Cilium Ingress (task #7) — the
        # dashboard itself stays plaintext on its ClusterIP.
        ssl: false

      # ─── Storage ─────────────────────────────────────────────────
      # Direct device discovery: Rook's OSD prepare job for each
      # node picks up the disk under the by-id path the microvm
      # gives it, runs `ceph-volume raw prepare --bluestore`, and
      # launches an OSD daemon. No CSI / StorageClass involved.
      storage:
        useAllNodes: false
        useAllDevices: false
        nodes:
${perNodeDevicesYaml}

      # ─── Placement ────────────────────────────────────────────────
      # MONs prefer control planes (etcd/apiserver-bearing nodes).
      # `all` tolerations are defensive — kubelet doesn't taint CPs
      # in this repo today, but we want Rook daemons to schedule even
      # if that changes.
      placement:
        all:
          tolerations:
          - key: "node-role.kubernetes.io/control-plane"
            operator: "Exists"
            effect: "NoSchedule"
        mon:
          tolerations:
          - key: "node-role.kubernetes.io/control-plane"
            operator: "Exists"
            effect: "NoSchedule"
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
              - matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: Exists
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values: [rook-ceph-mon]
              topologyKey: kubernetes.io/hostname
        mgr:
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values: [rook-ceph-mgr]
              topologyKey: kubernetes.io/hostname

      # ─── Resources ────────────────────────────────────────────────
      # Sized for the 10 GiB CP / 8 GiB worker lab budget.
      resources:
        mon:
          limits:
            memory: 1Gi
          requests:
            cpu: 50m
            memory: 256Mi
        mgr:
          limits:
            memory: 1Gi
          requests:
            cpu: 100m
            memory: 512Mi
        osd:
          # 2Gi minimum because parse_env computes osd_memory_target as
          # POD_MEMORY_LIMIT * osd_memory_target_cgroup_limit_ratio
          # (default 0.8) and asserts if the result is below the
          # osd_memory_target floor (~939 MB). 1Gi limit → 819 MB target
          # → crash at config init. 2Gi → 1.6 GB target → OK.
          limits:
            memory: 2Gi
          requests:
            cpu: 200m
            memory: 1Gi
        prepareosd:
          limits:
            memory: 512Mi
          requests:
            cpu: 100m
            memory: 128Mi
        mds:
          limits:
            memory: 1Gi
          requests:
            cpu: 100m
            memory: 256Mi

    # ─── Block pool (RBD) ───────────────────────────────────────────
    cephBlockPools:
    - name: replicapool
      spec:
        failureDomain: host
        replicated:
          size: 3
      storageClass:
        enabled: true
        name: ceph-block
        isDefault: true
        reclaimPolicy: Delete
        allowVolumeExpansion: true
        # The chart's templates/cephblockpool.yaml does NOT add CSI
        # secret references — the example values.yaml expects users to
        # include them in `parameters`. Without them, dynamic
        # provisioning fails with "provided secret is empty".
        parameters:
          imageFormat: "2"
          imageFeatures: layering
          csi.storage.k8s.io/fstype: ext4
          csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
          csi.storage.k8s.io/provisioner-secret-namespace: ${constants.ceph.namespace}
          csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
          csi.storage.k8s.io/controller-expand-secret-namespace: ${constants.ceph.namespace}
          csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
          csi.storage.k8s.io/node-stage-secret-namespace: ${constants.ceph.namespace}

    # ─── Shared filesystem (CephFS, RWX) ───────────────────────────
    cephFileSystems:
    - name: ceph-filesystem
      spec:
        metadataPool:
          replicated:
            size: 3
        dataPools:
        - name: data0
          failureDomain: host
          replicated:
            size: 3
        metadataServer:
          activeCount: 1
          activeStandby: true
          resources:
            limits:
              memory: 1Gi
            requests:
              cpu: 100m
              memory: 256Mi
      storageClass:
        enabled: true
        name: ceph-filesystem
        isDefault: false
        reclaimPolicy: Delete
        allowVolumeExpansion: true
        parameters:
          csi.storage.k8s.io/fstype: ext4
          csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
          csi.storage.k8s.io/provisioner-secret-namespace: ${constants.ceph.namespace}
          csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
          csi.storage.k8s.io/controller-expand-secret-namespace: ${constants.ceph.namespace}
          csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
          csi.storage.k8s.io/node-stage-secret-namespace: ${constants.ceph.namespace}

    # ─── Object store (RGW, S3) ────────────────────────────────────
    # Chart default uses erasure coding for the data pool (2+1).
    # We use replication-3 instead — the 4×10 GiB raw budget doesn't
    # comfortably support EC alongside the RBD + CephFS pools.
    cephObjectStores:
    - name: ceph-objectstore
      spec:
        metadataPool:
          failureDomain: host
          replicated:
            size: 3
        dataPool:
          failureDomain: host
          replicated:
            size: 3
        preservePoolsOnDelete: false
        gateway:
          port: 80
          instances: 2
          resources:
            limits:
              memory: 1Gi
            requests:
              cpu: 200m
              memory: 256Mi
      storageClass:
        enabled: true
        name: ceph-bucket
        reclaimPolicy: Delete

    # The chart's snapshot classes are off by default; leave them off.
    cephBlockPoolsVolumeSnapshotClass:
      enabled: false
    cephFileSystemVolumeSnapshotClass:
      enabled: false
  '';

  renderedCluster = helm.renderChart {
    name        = "rook-ceph-cluster";
    releaseName = "rook-ceph";
    namespace   = constants.ceph.namespace;
    chart       = constants.helmCharts.rookCephCluster;
    values      = clusterValuesYaml;
  };
in
{
  manifests = [
    {
      name = "rook-cluster/install.yaml";
      source = "${renderedCluster}/install.yaml";
    }
    {
      name = "rook-cluster/values.yaml";
      content = clusterValuesYaml;
    }

    # ─── Ingress: dashboard + S3 ───────────────────────────────────
    # Both share the existing cilium-ingress LoadBalancer Service
    # (VIP 10.33.33.50). Sync-wave 1 so they land after the
    # CephCluster + RGW Services that the chart creates at wave 0.
    #
    # Dashboard: cert-manager issues a TLS cert from selfsigned-lab
    # (defined in cert-manager.nix) for ceph.lab.local; the Ingress
    # terminates TLS and proxies to rook-ceph-mgr-dashboard:7000
    # (plaintext because dashboard.ssl=false in the chart values).
    #
    # S3: plaintext HTTP at s3.lab.local → rook-ceph-rgw-ceph-objectstore:80.
    # Path-style addressing only (`s3.lab.local/<bucket>/<key>`); the
    # shared ingress can't do virtual-host style without a wildcard
    # cert and a wildcard DNS entry. Use
    # `aws --endpoint http://s3.lab.local --addressing-style path` from
    # the dev box.
    {
      name = "rook-cluster/dashboard-certificate.yaml";
      content = ''
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: ceph-dashboard-tls
          namespace: ${constants.ceph.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          secretName: ceph-dashboard-tls
          duration: 720h0m0s     # 30 days
          renewBefore: 168h0m0s  # 7 days
          dnsNames:
          - ${constants.ceph.dashboard.host}
          issuerRef:
            name: selfsigned-lab
            kind: ClusterIssuer
            group: cert-manager.io
      '';
    }
    {
      name = "rook-cluster/dashboard-ingress.yaml";
      content = ''
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: ceph-dashboard
          namespace: ${constants.ceph.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          ingressClassName: cilium
          tls:
          - hosts:
            - ${constants.ceph.dashboard.host}
            secretName: ceph-dashboard-tls
          rules:
          - host: ${constants.ceph.dashboard.host}
            http:
              paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: rook-ceph-mgr-dashboard
                    port:
                      number: 7000
      '';
    }
    {
      name = "rook-cluster/rgw-ingress.yaml";
      content = ''
        apiVersion: networking.k8s.io/v1
        kind: Ingress
        metadata:
          name: ceph-rgw
          namespace: ${constants.ceph.namespace}
          annotations:
            argocd.argoproj.io/sync-wave: "1"
        spec:
          ingressClassName: cilium
          rules:
          - host: ${constants.ceph.rgw.host}
            http:
              paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    # Rook names the RGW Service after the CephObjectStore.
                    # cephObjectStores[0].name = "ceph-objectstore" above.
                    name: rook-ceph-rgw-ceph-objectstore
                    port:
                      number: 80
      '';
    }
    {
      name = "rook-cluster/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: rook-cluster
          namespace: argocd
          annotations:
            argocd.argoproj.io/sync-wave: "0"
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/rook-cluster
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
          # Rook mutates CephCluster status fields; ignore them in
          # diffs so ArgoCD doesn't flap.
          ignoreDifferences:
          - group: ceph.rook.io
            kind: CephCluster
            jsonPointers:
            - /spec/security
            - /status
      '';
    }
  ];
}
