# nix/secrets-gen.nix
#
# Generates SSH material into ./secrets/ for offline pre-generation:
#
#   - ssh-ed25519, ssh-ed25519.pub                   — user keypair for SSH'ing into VMs
#   - host-keys/k8s-<node>, host-keys/k8s-<node>.pub — per-node sshd host keypairs
#   - known_hosts                                    — for the host's SSH client
#
# Usage:
#   nix run .#k8s-gen-secrets             # generate (refuses if dir exists)
#   nix run .#k8s-gen-secrets -- --force  # regenerate (overwrites)
#
# Password auth and `sshpass` are NOT used anywhere; key-based auth
# with strict host-key checking is the only path in / out of the VMs.
#
{ pkgs }:
let
  constants = import ./constants.nix;
  # `node ip` table, expanded into the shell script at Nix eval time.
  ipTable = builtins.concatStringsSep "\n" (builtins.map (n:
    "  [${n}]=\"${constants.network.ipv4.${n}}\""
  ) constants.nodeNames);
in
{
  genSecrets = pkgs.writeShellApplication {
    name = "k8s-gen-secrets";
    runtimeInputs = with pkgs; [ coreutils openssh git gnugrep ];
    text = ''
      set -euo pipefail

      FORCE="no"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --force) FORCE="yes"; shift ;;
          *) echo "Usage: k8s-gen-secrets [--force]" >&2; exit 2 ;;
        esac
      done

      DIR="./secrets"

      if [[ -d "$DIR" && "$FORCE" != "yes" ]]; then
        echo "secrets/ already exists ($(find "$DIR" -type f | wc -l) files)."
        echo "Pass --force to regenerate."
        find "$DIR" -type f -printf '%P\n' | sort
        exit 1
      fi

      rm -rf "$DIR"
      mkdir -p "$DIR/host-keys"
      chmod 700 "$DIR" "$DIR/host-keys"

      echo "=== Generating user SSH keypair ==="
      # Used to authenticate FROM the host TO the VMs. Public half is
      # baked into root's authorized_keys at VM build time.
      ssh-keygen -t ed25519 -f "$DIR/ssh-ed25519" -N "" -C "ceph-on-k8s-host" -q

      echo "=== Generating per-node sshd host keypairs ==="
      # Build-time host keys baked into each VM image. The matching
      # known_hosts entries below let the host trust them without TOFU.
      declare -A NODE_IPS=(
${ipTable}
      )

      : > "$DIR/known_hosts"
      for node in ${builtins.concatStringsSep " " constants.nodeNames}; do
        hostname="k8s-$node"
        ssh-keygen -t ed25519 -f "$DIR/host-keys/$hostname" -N "" \
          -C "root@$hostname" -q
        # known_hosts format: '<host>[,<host>...] <keytype> <pubkey>'
        # We add two entries per node: by IPv4 and by short hostname.
        pubkey="$(awk '{print $1, $2}' "$DIR/host-keys/$hostname.pub")"
        ip="''${NODE_IPS[$node]}"
        echo "$ip $pubkey"        >> "$DIR/known_hosts"
        echo "$hostname $pubkey"  >> "$DIR/known_hosts"
      done

      chmod 600 "$DIR/ssh-ed25519" "$DIR"/host-keys/k8s-*
      chmod 644 "$DIR/ssh-ed25519.pub" "$DIR"/host-keys/*.pub "$DIR/known_hosts"

      # Nix flakes only see git-tracked files; `git add -N` lets
      # `builtins.pathExists` / `readFile` work without committing.
      # Review discipline keeps the private halves out of commits;
      # .gitignore explicitly excludes secrets/ssh-ed25519 and the
      # host-keys/ private keys.
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git add --intent-to-add "$DIR" 2>/dev/null || true
        echo "(staged secrets/ for Nix -- do not 'git add' the private keys)"
      fi

      echo ""
      echo "=== Generated $(find "$DIR" -type f | wc -l) files in $DIR/ ==="
      find "$DIR" -type f -printf '  %P\n' | sort
      echo ""
      echo "Next:"
      echo "  nix run .#k8s-render-manifests   # if you also changed nix/gitops/"
      echo "  nix run .#k8s-cluster-rebuild    # pick up the new keys"
    '';
  };
}
