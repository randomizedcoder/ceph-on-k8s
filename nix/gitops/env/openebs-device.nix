# nix/gitops/env/openebs-device.nix
#
# OpenEBS Local PV Device — raw-block CSI provisioner backing Rook OSDs.
#
# Upstream is the static `device-operator.yaml` manifest (no Helm chart
# is published). We fetch it via the rendered-manifest pattern, the
# same shape `cert-manager.nix` uses for cert-manager's upstream YAML.
#
# Discovery model:
#   - Each VM has a raw 10 GiB disk exposed as
#     /dev/disk/by-id/virtio-ceph-osd-<host> (configured in
#     nix/microvm.nix).
#   - The NixOS oneshot `ceph-disk-init` (in nix/k8s-module.nix)
#     creates a single GPT partition labeled `${diskPartLabel}` on
#     each node before kubelet starts.
#   - The OpenEBS `openebs-device-node` DaemonSet auto-discovers any
#     GPT partition whose label matches the StorageClass's
#     `parameters.devname`, registering it in a DeviceNode CR.
#   - A PVC with `volumeMode: Block` from `openebs-device` binds to
#     a matching partition; the CSI controller picks a node with an
#     available labeled partition.
#
# This is what Rook's `storageClassDeviceSets` (task #6) consumes
# to create PVC-based OSDs.
#
{ pkgs, lib }:
let
  constants = import ../../constants.nix;

  upstreamManifest = pkgs.fetchurl {
    url  = constants.openebsDeviceLocalpv.url;
    hash = constants.openebsDeviceLocalpv.hash;
  };
in
{
  manifests = [
    # Upstream device-operator.yaml: namespace, CRDs (devicevolumes,
    # devicenodes), CSIDriver, ServiceAccounts, ClusterRoles,
    # StatefulSet (controller), DaemonSet (node agent).
    {
      name = "openebs-device/upstream.yaml";
      source = "${upstreamManifest}";
    }

    # The StorageClass Rook will pull OSD PVCs from. WaitForFirstConsumer
    # so the CSI controller picks the node where the workload schedules,
    # rather than binding eagerly to any node with an available partition.
    {
      name = "openebs-device/storageclass.yaml";
      content = ''
        apiVersion: storage.k8s.io/v1
        kind: StorageClass
        metadata:
          name: ${constants.openebs.storageClassName}
          annotations:
            argocd.argoproj.io/sync-wave: "-2"
        provisioner: device.csi.openebs.io
        allowVolumeExpansion: false
        volumeBindingMode: WaitForFirstConsumer
        reclaimPolicy: Delete
        parameters:
          devname: "${constants.openebs.diskPartLabel}"
      '';
    }

    # ArgoCD takes over reconciliation after the bootstrap unit applies
    # the upstream + storageclass YAMLs at first boot. Sync-wave -2 so
    # this lands before Rook (which uses sync-wave -1 for the operator
    # and 0 for the CephCluster CR in tasks #5 and #6).
    {
      name = "openebs-device/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: openebs-device
          namespace: argocd
          annotations:
            argocd.argoproj.io/sync-wave: "-2"
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/openebs-device
            directory:
              recurse: false
              exclude: 'application.yaml'
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
