# nix/microvm-client.nix
#
# Parametric NixOS-microvm generator for an EXTERNAL Ceph client.
# The VM:
#   - sits on the same k8sbr0 bridge as the K8s cluster nodes
#   - is NOT a Kubernetes node (no kubelet / etcd / apiserver)
#   - has the kernel CephFS client + `ceph-client` userland
#   - mounts the cluster's CephFS at /mnt/cephfs at boot
#
# Most of the scaffolding (microvm hypervisor wiring, 9p store share,
# TAP networking, hardened sshd, build-time host-key activation) is
# lifted directly from nix/microvm.nix — only the K8s-specific bits
# are removed.
#
# Returns microvm.declaredRunner — a script that starts the VM.
#
{
  pkgs,
  lib,
  microvm,
  nixpkgs,
  system,
  nodeName,                  # "client0"
  hostKey ? null,            # Per-node sshd host PRIVATE key (path). REQUIRED.
  sshPubKey ? null,          # User SSH pubkey for root's authorized_keys
  cephConf ? null,           # Nix-store path to /etc/ceph/ceph.conf
  cephKeyring ? null,        # Path to ./secrets/cephfs-client.keyring (for /etc/ceph)
  cephClientSecret ? null,   # Base64 CephX secret (string) — inlined into mount options
}:
let
  constants = import ./constants.nix;

  hostname     = constants.getHostname nodeName;
  consolePorts = constants.getConsolePorts nodeName;

  nodeIp4 = constants.network.ipv4.${nodeName};
  nodeIp6 = constants.network.ipv6.${nodeName};
  mac     = constants.network.macs.${nodeName};
  tap     = constants.network.taps.${nodeName};

  cu = constants.ceph.externalClient;

  # CephFS mount device string. MONs run on hostNetwork (see the
  # constants.ceph comment) so we point straight at the node IPs on
  # port 6789 (msgr-v1, the kernel client default). Trailing `:/`
  # asks for the root of the filesystem; the `mds_namespace=` option
  # in fileSystems.options selects the CephFS.
  monMountTarget = lib.concatStringsSep "," constants.ceph.monHosts + ":/";

  vmConfig = nixpkgs.lib.nixosSystem {
    inherit system;

    modules = [
      microvm.nixosModules.microvm

      ({ config, pkgs, ... }: {
        system.stateVersion = "26.05";
        nixpkgs.hostPlatform = system;

        microvm = {
          hypervisor = "qemu";
          # 2 GiB / 2 vCPUs — vcpu=2 so the TAP queue count matches
          # the multi-queue TAP created by nix/network-setup.nix
          # (vcpu=1 makes the netdev string omit `queues=` which
          # then fails to bind to the multi-queue TAP with
          # "Invalid argument"). Avoid exact powers of two; QEMU
          # hangs on some hosts with 2048.
          mem = 2047;
          vcpu = 2;

          shares = [{
            tag = "ro-store";
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            proto = "9p";
          }];

          # Single 4 GiB data volume for /var/lib (journald, /home root
          # if any, etc). No second disk — the client doesn't host OSDs.
          volumes = [{
            image = "${hostname}-data.img";
            mountPoint = "/var/lib";
            size = 4096;
          }];

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

        # Kernel CephFS client. The `ceph` module is the kernel mount
        # backend; `mount -t ceph` from `ceph-common` is the userland
        # caller.
        boot.kernelModules = [ "ceph" ];

        networking.hostName = hostname;

        # Static dual-stack IP via systemd-networkd (same shape as
        # nix/microvm.nix).
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
            routes = [ { Gateway = constants.network.gateway4; } ];
          };
        };
        networking.useDHCP = false;

        # SSH: same hardened config as the cluster nodes — key-based
        # auth only, host key baked in at build time.
        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = lib.mkForce false;
            KbdInteractiveAuthentication = lib.mkForce false;
            PermitRootLogin = lib.mkForce "prohibit-password";
          };
          hostKeys = [
            { type = "ed25519"; path = "/etc/ssh/ssh_host_ed25519_key"; }
          ];
        };
        users.users.root = {
          hashedPassword = "!";
          openssh.authorizedKeys.keys =
            lib.optional (sshPubKey != null) sshPubKey;
        };

        # No ceph userland — the mount string below uses the kernel's
        # `secret=` option directly (the base64 key is inlined at Nix
        # eval time), so no `mount.ceph` helper is needed. nixpkgs'
        # `ceph` / `ceph-client` packages currently pull in a Python
        # tree that conflicts with the active Sphinx version, so we
        # avoid them entirely.
        environment.systemPackages = with pkgs; [
          util-linux  # findmnt, mount/umount
          bonnie      # bonnie++ — disk-I/O benchmark for /mnt/cephfs
        ];

        # ─── SSH host key activation (same as nix/microvm.nix) ─────────
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

        # ─── /etc/ceph: conf + keyring baked in at build time ─────────
        # Both files come from secrets.nix (built in-Nix for cephConf,
        # from secrets/cephfs-client.keyring for the keyring). The
        # keyring isn't needed for the mount itself (we inline the key
        # into the mount options below) but it's installed so a future
        # interactive `ceph -n client.external` from the VM works.
        # Same "fail loudly on missing" pattern as the SSH host key.
        system.activationScripts.ceph-config = ''
          ${if cephConf == null || cephKeyring == null then ''
            echo "ERROR: no Ceph config / keyring supplied. Run 'nix run .#k8s-gen-secrets' first." >&2
            exit 1
          '' else ''
            install -d -m 0755 /etc/ceph
            install -m 0644 ${cephConf}    /etc/ceph/ceph.conf
            install -m 0600 ${cephKeyring} /etc/ceph/ceph.client.${cu.user}.keyring
          ''}
        '';

        # ─── CephFS mount ─────────────────────────────────────────────
        # NixOS-native fileSystems entry → systemd .mount unit. The
        # secret is inlined here (base64 from secrets.nix) so the
        # kernel ceph client can mount without invoking the userland
        # `mount.ceph` helper (which would require pulling in the
        # broken `ceph` package). Mount is best-effort at boot
        # (`nofail`) so SSH still comes up if the MONs are unreachable.
        fileSystems.${cu.mountDir} = lib.mkIf (cephClientSecret != null) {
          device = monMountTarget;
          fsType = "ceph";
          options = [
            "name=${cu.user}"
            "secret=${cephClientSecret}"
            # Newer kernel CephFS clients use mds_namespace= (the
            # older `fs=` is rejected with "Unknown parameter 'fs'").
            "mds_namespace=${cu.fsName}"
            "noatime"
            "_netdev"
            "x-systemd.requires=network-online.target"
            "x-systemd.after=network-online.target"
            "nofail"
          ];
        };

        # Make sure network-online.target is actually waited on (sshd
        # ordering implies network, but the cephfs mount unit explicitly
        # requires it).
        systemd.targets.network-online.wantedBy = [ "multi-user.target" ];

        # Disable firewall — same as the cluster nodes; lab network.
        networking.firewall.enable = false;
      })
    ];
  };
in
vmConfig.config.microvm.declaredRunner
