# nix/secrets.nix
#
# Reads pre-generated secrets from ./secrets/ and exposes the SSH public
# key for MicroVM authorized_keys. The CNPG/Matrix/PowerDNS/Forgejo/etc.
# Secret manifests from the source repo have been removed — Rook
# generates its own dashboard admin password, and no other application
# needs offline-generated secrets in this repo.
#
# If ./secrets/ does not exist, returns null values so the cluster still
# builds without an SSH key (password fallback on the serial console).
#
{ pkgs, lib }:
let
  secretsDir = ../secrets;
  hasSecrets = builtins.pathExists secretsDir;
in
if !hasSecrets then { k8sSecrets = null; sshPubKey = null; }
else
let
  sshPubKeyFile = secretsDir + "/ssh-ed25519.pub";
  sshPubKey = if builtins.pathExists sshPubKeyFile
    then lib.trim (builtins.readFile sshPubKeyFile)
    else null;
in
{
  # No K8s Secret manifests to apply at bootstrap. Future ceph-related
  # offline secrets (e.g. a deterministic S3 access keypair) could be
  # added here following the source repo's runCommand + jq pattern.
  k8sSecrets = null;
  inherit sshPubKey;
}
