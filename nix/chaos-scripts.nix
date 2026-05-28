# nix/chaos-scripts.nix
#
# Chaos / failover verification tool — STUB.
#
# The source repo's version killed cluster nodes and measured
# PostgreSQL/TiDB/ClickHouse/FoundationDB recovery. This repo replaces
# that with an OSD-failover test that kills a node and measures
# CephCluster recovery to HEALTH_OK.
#
# The full rewrite is task #9 in the plan; for now this is a stub so
# the flake still builds. Invoking it prints a guidance message.
#
{ pkgs }:
{
  chaosFailover = pkgs.writeShellApplication {
    name = "k8s-chaos-failover";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      set -euo pipefail
      cat >&2 <<'EOF'
      k8s-chaos-failover is not yet implemented for ceph-on-k8s.

      The source repo's CNPG/TiDB/ClickHouse/FoundationDB chaos test has been
      removed and not yet replaced. Task #9 in /home/das/.claude/profiles/
      personal/plans/o-curried-toucan.md will rewrite this to kill cluster
      nodes and measure Rook-Ceph OSD recovery to HEALTH_OK.

      Until then: bring up the cluster with `nix run .#k8s-cluster-rebuild`
      and verify storage manually with `kubectl exec -n rook-ceph deploy/
      rook-ceph-tools -- ceph -s`.
      EOF
      exit 1
    '';
  };
}
