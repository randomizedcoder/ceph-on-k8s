# nix/nodes.nix
#
# Node definitions.
#
# - `definitions`        : K8s cluster members (3 CP + 1 worker)
# - `clientDefinitions`  : external Ceph clients (NOT part of the K8s cluster).
#                          Same TAP/IP/key infrastructure as cluster nodes
#                          but driven by a separate microvm generator.
#
{ constants }:
rec {
  definitions = {
    cp0 = {
      role = "control-plane";
      nodeIndex = 0;
      description = "Control plane 0 (etcd, apiserver, controller-manager, scheduler)";
      services = [
        "etcd" "kube-apiserver" "kube-controller-manager" "kube-scheduler"
        "containerd" "kubelet"
      ];
    };

    cp1 = {
      role = "control-plane";
      nodeIndex = 1;
      description = "Control plane 1 (etcd, apiserver, controller-manager, scheduler)";
      services = [
        "etcd" "kube-apiserver" "kube-controller-manager" "kube-scheduler"
        "containerd" "kubelet"
      ];
    };

    cp2 = {
      role = "control-plane";
      nodeIndex = 2;
      description = "Control plane 2 (etcd, apiserver, controller-manager, scheduler)";
      services = [
        "etcd" "kube-apiserver" "kube-controller-manager" "kube-scheduler"
        "containerd" "kubelet"
      ];
    };

    w3 = {
      role = "worker";
      nodeIndex = 3;
      description = "Worker node";
      services = [ "containerd" "kubelet" ];
    };
  };

  # External-client microvms. Same lab bridge, separate lifecycle.
  # `role = "ceph-client"` is informational; microvm-client.nix is
  # generic and just consumes nodeName + a few constants.
  clientDefinitions = {
    client0 = {
      role = "ceph-client";
      nodeIndex = 20;
      description = "External CephFS client (mounts /mnt/cephfs at boot)";
      services = [ "sshd" "mnt-cephfs.mount" ];
    };
  };

  nodeNames = builtins.attrNames definitions;
  clientNodeNames = builtins.attrNames clientDefinitions;
}
