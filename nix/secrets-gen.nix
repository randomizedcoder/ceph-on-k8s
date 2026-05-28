# nix/secrets-gen.nix
#
# Generates the SSH keypair into ./secrets/ for offline pre-generation.
#
# Usage:
#   nix run .#k8s-gen-secrets             # generate (refuses if dir exists)
#   nix run .#k8s-gen-secrets -- --force  # regenerate (overwrites)
#
# The source repo's matrix/anubis/observability/registry/pdns/forgejo
# secret generation has been removed; this repo only needs an SSH key
# for VM access (Rook generates its own dashboard admin password).
#
{ pkgs }:
{
  genSecrets = pkgs.writeShellApplication {
    name = "k8s-gen-secrets";
    runtimeInputs = with pkgs; [ coreutils openssh git ];
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
        echo "secrets/ already exists ($(find "$DIR" -maxdepth 1 -type f | wc -l) files)."
        echo "Pass --force to regenerate."
        find "$DIR" -maxdepth 1 -type f -printf '%f\n' | sort
        exit 1
      fi

      mkdir -p "$DIR"
      chmod 700 "$DIR"

      echo "=== Generating SSH keypair for MicroVM access ==="

      # ED25519 key pair. The public key is baked into each VM at build
      # time (authorized_keys); the private key stays on the host.
      ssh-keygen -t ed25519 -f "$DIR/ssh-ed25519" -N "" -C "ceph-on-k8s" -q

      chmod 600 "$DIR"/*
      chmod 644 "$DIR/ssh-ed25519.pub"

      # Nix flakes can only read git-tracked files. Stage the SSH pubkey
      # so `builtins.pathExists` and `readFile` work during Nix eval.
      # The private key is git-ignored via secrets/ being excluded from
      # the regular gitignore but the user must avoid committing it.
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git add "$DIR" 2>/dev/null || true
        echo "(staged secrets/ for Nix — remember to 'git reset secrets/' before committing)"
      fi

      echo ""
      echo "=== Generated $(find "$DIR" -maxdepth 1 -type f | wc -l) files in $DIR/ ==="
      find "$DIR" -maxdepth 1 -type f -printf '%f\n' | sort
      echo ""
      echo "Next: rebuild the cluster to pick up the new keypair."
      echo "  nix run .#k8s-cluster-rebuild"
    '';
  };
}
