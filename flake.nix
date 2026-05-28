#
# flake.nix - ceph-on-k8s: 4-Node K8s + Rook Ceph via NixOS MicroVMs
#
# 3 control planes + 1 worker, running as lightweight QEMU MicroVMs with
# TAP networking. Each VM has a dedicated 10 GiB raw block disk attached
# for OpenEBS to discover and Rook-Ceph to consume as PVC-based OSDs.
# Cilium CNI (replacing kube-proxy), dual-stack IPv4/IPv6, host-side
# haproxy for apiserver HA, and GitOps deployment via ArgoCD.
#
# Architecture:
#   Host ─── k8sbr0 (bridge) ─┬─ k8stap0 → cp0  10.33.33.10  (etcd, apiserver, scheduler, CM, ceph MON/MGR/OSD)
#            haproxy:6443 ──┐  ├─ k8stap1 → cp1  10.33.33.11  (etcd, apiserver, scheduler, CM, ceph MON/MGR/OSD)
#            (LB → 3 CPs)  │  ├─ k8stap2 → cp2  10.33.33.12  (etcd, apiserver, scheduler, CM, ceph MON/OSD)
#                           └──└─ k8stap3 → w3   10.33.33.13  (kubelet, containerd, ceph OSD)
#
# Quick Start:
#   nix develop                          # Dev shell (kubectl, helm, cilium-cli, step-cli, ...)
#   nix run .#k8s-check-host             # Verify host prereqs (tun, vhost-net, bridge)
#   sudo nix run .#k8s-network-setup     # Create bridge + 4 TAPs + NAT + haproxy LB
#   nix run .#k8s-gen-secrets            # Generate SSH keypair into ./secrets/
#   nix run .#k8s-render-manifests       # Render Helm charts into ./rendered/
#   nix run .#k8s-start-all              # Build + start all 4 VMs
#   nix run .#k8s-vm-ssh -- --node=cp0 kubectl get nodes
#
# Teardown:
#   nix run .#k8s-vm-stop                # Stop all VMs
#   sudo nix run .#k8s-network-teardown  # Remove bridge, TAPs, NAT, haproxy
#
# See docs/ceph-design.md and docs/nix-design.md for the full design.
#
{
  description = "ceph-on-k8s: 4-node K8s + Rook-Ceph on NixOS MicroVMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      microvm,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        nixDir = ./nix;
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        constants = import (nixDir + "/constants.nix");
        nodes = import (nixDir + "/nodes.nix") { inherit constants; };
        k8sModule = import (nixDir + "/k8s-module.nix");
        monitoringModule = import (nixDir + "/monitoring-module.nix");
        bootstrapModule = import (nixDir + "/gitops-bootstrap-module.nix");

        # Import cert generation (build-time PKI)
        certs = import (nixDir + "/certs.nix") { inherit pkgs lib; };

        # Import secrets pre-generation (reads ./secrets/ if it exists)
        secrets = import (nixDir + "/secrets.nix") {
          inherit pkgs lib;
        };
        k8sSecrets       = secrets.k8sSecrets;       # null if ./secrets/ doesn't exist
        sshPubKey        = secrets.sshPubKey;        # null if no user SSH key generated
        hostKeyPath      = secrets.hostKeyPath;      # nodeName -> path|null
        knownHostsPath   = secrets.knownHostsPath;   # null if not generated

        # Secrets generation script
        secretsGen = import (nixDir + "/secrets-gen.nix") { inherit pkgs; };

        # GitOps manifest generator (also consumed by the bootstrap unit).
        # `secrets` is passed through so ceph-external-client can embed
        # the CephX secret key in its Kubernetes Secret manifest.
        gitops = import (nixDir + "/gitops") { inherit pkgs lib secrets; };
        k8sManifests = gitops.packages.k8s-manifests;

        # ─── MicroVM Generator ───────────────────────────────────────────
        mkK8sNode = { nodeName, role }:
          import (nixDir + "/microvm.nix") {
            inherit pkgs lib microvm k8sModule monitoringModule bootstrapModule nixpkgs system;
            inherit nodeName role;
            nodePki = certs.mkNodePki { inherit nodeName role; };
            inherit k8sManifests k8sSecrets sshPubKey;
            hostKey = hostKeyPath nodeName;
          };

        # Generate MicroVM packages for all nodes
        vmPackages = lib.mapAttrs' (name: def:
          lib.nameValuePair "k8s-microvm-${name}" (mkK8sNode {
            nodeName = name;
            inherit (def) role;
          })
        ) nodes.definitions;

        # ─── External Ceph-client MicroVM(s) ─────────────────────────────
        # Same TAP + SSH infrastructure as the cluster nodes, but a
        # separate generator with no K8s scaffolding. The client mounts
        # CephFS at /mnt/cephfs at boot using the build-time keyring
        # produced by k8s-gen-secrets and the matching CephX user
        # registered by the ceph-external-client env module.
        mkClientNode = { nodeName }:
          import (nixDir + "/microvm-client.nix") {
            inherit pkgs lib microvm nixpkgs system nodeName sshPubKey;
            hostKey          = hostKeyPath nodeName;
            cephConf         = secrets.cephConf;
            cephKeyring      = secrets.cephKeyringPath;
            cephClientSecret = secrets.cephClientSecret;
          };

        clientPackages = lib.mapAttrs' (name: _:
          lib.nameValuePair "k8s-microvm-${name}" (mkClientNode {
            nodeName = name;
          })
        ) nodes.clientDefinitions;

        # Import lifecycle testing framework (Linux only)
        lifecycle = lib.optionalAttrs pkgs.stdenv.isLinux (
          import (nixDir + "/lifecycle") { inherit pkgs lib knownHostsPath; }
        );

        # Rendered manifests script
        renderScript = import (nixDir + "/render-script.nix") { inherit pkgs; };

      in
      {
        packages = vmPackages // clientPackages // lib.optionalAttrs pkgs.stdenv.isLinux (
          # Lifecycle test packages
          (lifecycle.packages or {})
          # GitOps manifests
          // gitops.packages
          # Cert generation (copies build-time certs to ./certs/ for inspection)
          // { k8s-gen-certs = certs.genCerts; }
          # Raw PKI store (all certs)
          // { k8s-pki = certs.pkiStore; }
        );

        devShells.default = import (nixDir + "/shell.nix") { inherit pkgs; };

        # ─── Apps (Linux only) ─────────────────────────────────────────
        apps = lib.optionalAttrs pkgs.stdenv.isLinux (
          let
            networkScripts = import (nixDir + "/network-setup.nix") { inherit pkgs; };
            vmScripts = import (nixDir + "/microvm-scripts.nix") {
              inherit pkgs;
              inherit knownHostsPath;
            };
            chaosScripts = import (nixDir + "/chaos-scripts.nix") {
              inherit pkgs;
              inherit knownHostsPath;
            };
          in
          {
            # Network management
            k8s-check-host = {
              type = "app";
              program = "${networkScripts.check}/bin/k8s-check-host";
            };
            k8s-network-setup = {
              type = "app";
              program = "${networkScripts.setup}/bin/k8s-network-setup";
            };
            k8s-network-teardown = {
              type = "app";
              program = "${networkScripts.teardown}/bin/k8s-network-teardown";
            };

            # VM management
            k8s-vm-check = {
              type = "app";
              program = "${vmScripts.check}/bin/k8s-vm-check";
            };
            k8s-vm-stop = {
              type = "app";
              program = "${vmScripts.stop}/bin/k8s-vm-stop";
            };
            k8s-vm-stop-one = {
              type = "app";
              program = "${vmScripts.stopOne}/bin/k8s-vm-stop-one";
            };
            k8s-vm-start-one = {
              type = "app";
              program = "${vmScripts.startOne}/bin/k8s-vm-start-one";
            };
            k8s-vm-ssh = {
              type = "app";
              program = "${vmScripts.ssh}/bin/k8s-vm-ssh";
            };
            k8s-start-all = {
              type = "app";
              program = "${vmScripts.startAll}/bin/k8s-start-all";
            };
            k8s-vm-wipe = {
              type = "app";
              program = "${vmScripts.wipe}/bin/k8s-vm-wipe";
            };
            k8s-cluster-rebuild = {
              type = "app";
              program = "${vmScripts.clusterRebuild}/bin/k8s-cluster-rebuild";
            };

            # Certificates (copies build-time certs to ./certs/ for inspection)
            k8s-gen-certs = {
              type = "app";
              program = "${certs.genCerts}/bin/k8s-gen-certs";
            };

            # Secrets pre-generation (offline, into ./secrets/)
            k8s-gen-secrets = {
              type = "app";
              program = "${secretsGen.genSecrets}/bin/k8s-gen-secrets";
            };

            # Rendered manifests
            k8s-render-manifests = {
              type = "app";
              program = "${renderScript}/bin/k8s-render-manifests";
            };

            # Chaos / failover test (rewritten for OSD failover in task #9)
            k8s-chaos-failover = {
              type = "app";
              program = "${chaosScripts.chaosFailover}/bin/k8s-chaos-failover";
            };

            # External Ceph-client lifecycle (separate from k8s-start-all)
            k8s-client-start = {
              type = "app";
              program = "${vmScripts.clientStart}/bin/k8s-client-start";
            };
            k8s-client-stop = {
              type = "app";
              program = "${vmScripts.clientStop}/bin/k8s-client-stop";
            };
            k8s-client-wipe = {
              type = "app";
              program = "${vmScripts.clientWipe}/bin/k8s-client-wipe";
            };
          }

          # Lifecycle test apps
          // (lifecycle.apps or {})
        );
      }
    );
}
