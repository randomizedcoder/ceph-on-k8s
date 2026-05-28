# nix/microvm.nix
#
# Parametric MicroVM generator for K8s cluster nodes.
# Creates a MicroVM runner for a given node (cp0, w1, w2, w3).
#
# Certs are generated at Nix build time and baked into the VM image
# via activation scripts (copied from /nix/store to /var/lib/kubernetes/pki/).
#
# Returns microvm.declaredRunner - a script that starts the VM.
#
{
  pkgs,
  lib,
  microvm,
  k8sModule,
  monitoringModule,
  bootstrapModule,
  nixpkgs,
  system,
  nodeName,       # "cp0", "w1", "w2", "w3"
  role,           # "control-plane" or "worker"
  nodePki,        # Per-node PKI bundle (from certs.mkNodePki)
  k8sManifests,   # Rendered k8s manifests derivation
  k8sSecrets ? null,       # Pre-generated Secret manifests (from secrets.nix; null if absent)
  sshPubKey ? null,        # User SSH pubkey for root's authorized_keys (from secrets.nix; null if absent)
  hostKey ? null,          # Per-node sshd host PRIVATE key (path; from secrets.nix). REQUIRED — no fallback host-key generation
}:
let
  constants = import ./constants.nix;

  hostname = constants.getHostname nodeName;
  consolePorts = constants.getConsolePorts nodeName;
  resources = constants.getVmResources role;

  nodeIp4 = constants.network.ipv4.${nodeName};
  nodeIp6 = constants.network.ipv6.${nodeName};
  mac = constants.network.macs.${nodeName};
  tap = constants.network.taps.${nodeName};

  pki = constants.k8s.pkiDir;

  vmConfig = nixpkgs.lib.nixosSystem {
    inherit system;

    modules = [
      microvm.nixosModules.microvm
      k8sModule
      monitoringModule
      bootstrapModule

      ({ config, pkgs, ... }: {
        system.stateVersion = "26.05";
        nixpkgs.hostPlatform = system;

        microvm = {
          hypervisor = "qemu";
          mem = resources.memoryMB;
          vcpu = resources.vcpus;

          shares = [{
            tag = "ro-store";
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            proto = "9p";
          }];

          volumes = [
            {
              image = "${hostname}-data.img";
              mountPoint = "/var/lib";
              size = 20480;  # 20GB writable volume for containerd, etcd, kubelet
            }
            {
              # Raw OSD disk for Ceph. mountPoint=null → microvm.nix's
              # mounts.nix skips registering a filesystem (it gates on
              # mountPoint != null), so the guest kernel sees /dev/vdb
              # as untouched raw block — exactly what OpenEBS NDM wants.
              # The ext4 header that autoCreate=true writes gets wiped
              # by Rook's `ceph-volume` OSD prepare on first use.
              # 10 GiB is below Bluestore's recommended minimum but
              # sufficient to prove the configuration end-to-end with
              # the small ceph-demo workload. Bump via
              # constants.ceph.osd.diskSizeGi for real use.
              image = "${hostname}-ceph.img";
              mountPoint = null;
              size = 10240;  # 10 GiB
              autoCreate = true;
              fsType = "ext4";
              # Stable identity in the guest via /dev/disk/by-id/virtio-ceph-osd-*.
              # The CephCluster CR references this path rather than
              # /dev/vdb so volume-order changes can't bind the OSD to
              # the wrong physical disk.
              serial = "ceph-osd-${hostname}";
            }
          ];

          interfaces = [{
            type = "tap";
            id = tap;
            mac = mac;
          }];

          qemu = {
            serialConsole = false;
            extraArgs = [
              "-name" "${hostname},process=${hostname}"
              "-serial" "tcp:127.0.0.1:${toString consolePorts.serial},server,nowait"
              "-device" "virtio-serial-pci"
              "-chardev" "socket,id=virtcon,port=${toString consolePorts.virtio},host=127.0.0.1,server=on,wait=off"
              "-device" "virtconsole,chardev=virtcon"
            ];
          };
        };

        boot.kernelParams = [
          "console=ttyS0,115200"
          "console=hvc0"
        ];

        networking.hostName = hostname;

        # Static dual-stack IP via systemd-networkd
        systemd.network = {
          enable = true;
          networks."10-tap" = {
            matchConfig.Name = "enp*";
            networkConfig = {
              Address = [ "${nodeIp4}/24" "${nodeIp6}/64" ];
              Gateway = constants.network.gateway4;
              DHCP = "no";
              IPv6AcceptRA = false;
            };
            routes = [
              { Gateway = constants.network.gateway4; }
            ];
          };
        };
        networking.useDHCP = false;

        # SSH: key-based auth ONLY. No password / kbd-interactive.
        # Host key is the build-time per-node key from
        # ./secrets/host-keys/k8s-<node>, copied below by the
        # activation script. NixOS's default sshd would generate a
        # fresh host key on first boot; we disable that and provide
        # our own so the host's known_hosts entry matches deterministically.
        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = lib.mkForce false;
            KbdInteractiveAuthentication = lib.mkForce false;
            PermitRootLogin = lib.mkForce "prohibit-password";
          };
          # Don't let sshd run `ssh-keygen` on first boot; we own
          # the host keys.
          hostKeys = [
            { type = "ed25519"; path = "/etc/ssh/ssh_host_ed25519_key"; }
          ];
        };
        users.users.root = {
          # No password — key-based auth only.
          hashedPassword = "!";
          openssh.authorizedKeys.keys =
            lib.optional (sshPubKey != null) sshPubKey;
        };

        # ─── PKI: copy build-time certs to /var/lib/kubernetes/pki/ ────
        # Certs are in /nix/store (read-only). Copy to writable PKI dir at boot.
        system.activationScripts.k8s-pki = ''
          mkdir -p ${pki}
          cp -f ${nodePki}/* ${pki}/
          chmod 600 ${pki}/*.key 2>/dev/null || true
          chmod 644 ${pki}/*.crt ${pki}/*.pub 2>/dev/null || true
          chmod 600 ${pki}/*-kubeconfig 2>/dev/null || true
          chmod 644 ${pki}/kubelet-config.yaml 2>/dev/null || true
        '';

        # ─── SSH host key: copy build-time key into /etc/ssh ───────────
        # The matching pubkey is in the host's ./secrets/known_hosts,
        # so SSH connections from the host succeed without TOFU. If
        # hostKey is null (./secrets/ doesn't exist), bail out at
        # activation rather than silently letting sshd generate a fresh
        # key that nobody trusts.
        system.activationScripts.ssh-host-key = ''
          ${if hostKey == null then ''
            echo "ERROR: no SSH host key supplied. Run 'nix run .#k8s-gen-secrets' first." >&2
            exit 1
          '' else ''
            install -d -m 0755 /etc/ssh
            install -m 0600 ${hostKey}     /etc/ssh/ssh_host_ed25519_key
            install -m 0644 ${hostKey}.pub /etc/ssh/ssh_host_ed25519_key.pub
          ''}
        '';

        # K8s services
        services.k8s = {
          enable = true;
          inherit role;
          inherit nodeName;
          nodeIp4 = nodeIp4;
          nodeIp6 = nodeIp6;
        };

        # Prometheus + Grafana only on the designated monitoring host.
        services.k8s-monitoring.enable = (nodeName == constants.prometheus.host);

        # First-boot GitOps bootstrap only on cp0.
        services.k8s-gitops-bootstrap = {
          enable = (nodeName == "cp0");
          manifestsPath = k8sManifests;
          secretsPath = k8sSecrets;
        };
      })
    ];
  };
in
vmConfig.config.microvm.declaredRunner
