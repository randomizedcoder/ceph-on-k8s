# nix/chaos-scripts.nix
#
# OSD-failover chaos test for Rook-Ceph.
#
# Loops through the cluster's 4 MicroVMs, kills one at a time, and
# measures how long Ceph takes to return to HEALTH_OK after each kill
# (and after the node rejoins). With one OSD per host, killing a node
# takes one OSD with it; the cluster goes to HEALTH_WARN until the
# node returns and the OSD re-joins, then HEALTH_OK.
#
# Output:
#   chaos-logs/summary.tsv  — round, node, status_at_kill,
#                              warn_seconds, recover_seconds
#   chaos-logs/events.log   — timestamped event log
#
# See README "Chaos / Failover Test" section for usage.
#
{ pkgs }:
let
  constants = import ./constants.nix;
  vmScripts = import ./microvm-scripts.nix { inherit pkgs; };
in
{
  chaosFailover = pkgs.writeShellApplication {
    name = "k8s-chaos-failover";
    runtimeInputs = with pkgs; [
      bc gawk coreutils procps gnused sshpass openssh
    ];
    text = ''
      set -uo pipefail

      # ─── Defaults (from constants.nix) ───────────────────────────────
      ROUNDS=${toString constants.chaos.defaultRounds}
      INTERVAL=${toString constants.chaos.defaultIntervalSec}
      POST_ROUND_WAIT=${toString constants.chaos.defaultPostRoundWait}
      WARMUP=${toString constants.chaos.defaultWarmupSec}
      LOG_DIR="${constants.chaos.defaultLogDir}"
      NODES="cp0,cp1,cp2,w3"
      EXPECTED_OSDS=${toString (builtins.length constants.nodeNames)}

      CP0_IP="${constants.network.ipv4.cp0}"
      SSH_PASS="${constants.ssh.password}"
      CEPH_NS="${constants.ceph.namespace}"

      usage() {
        cat <<EOF
      Usage: k8s-chaos-failover [OPTIONS]

      Kills one K8s MicroVM at a time, measures Ceph recovery, repeats.

      Options:
        --rounds=N             Number of rounds (default: $ROUNDS)
        --interval=SEC         Minimum seconds between kills (default: $INTERVAL)
        --post-round-wait=SEC  Seconds to wait after node rejoins (default: $POST_ROUND_WAIT)
        --warmup=SEC           Seconds to let cluster stabilise (default: $WARMUP)
        --nodes=LIST           Comma-separated nodes (default: $NODES)
        --log-dir=DIR          Output directory (default: $LOG_DIR)
        --expected-osds=N      Expected OSDs (default: $EXPECTED_OSDS)
        -h, --help             Show this help

      Requires: cluster running, cp0 reachable via SSH.
      EOF
      }

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --rounds=*)          ROUNDS="''${1#*=}"; shift ;;
          --interval=*)        INTERVAL="''${1#*=}"; shift ;;
          --post-round-wait=*) POST_ROUND_WAIT="''${1#*=}"; shift ;;
          --warmup=*)          WARMUP="''${1#*=}"; shift ;;
          --nodes=*)           NODES="''${1#*=}"; shift ;;
          --log-dir=*)         LOG_DIR="''${1#*=}"; shift ;;
          --expected-osds=*)   EXPECTED_OSDS="''${1#*=}"; shift ;;
          -h|--help)           usage; exit 0 ;;
          *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
        esac
      done

      mkdir -p "$LOG_DIR"
      SUMMARY="$LOG_DIR/summary.tsv"
      EVENTS="$LOG_DIR/events.log"
      : > "$SUMMARY"
      : > "$EVENTS"
      printf "round\tnode\tpre_kill_status\twarn_sec\trecover_sec\trejoin_sec\n" > "$SUMMARY"

      log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$EVENTS"; }

      # ─── kubectl + ceph via SSH to cp0 ────────────────────────────────
      ssh_cp0() {
        sshpass -p "$SSH_PASS" ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          "root@$CP0_IP" \
          "$@"
      }

      kctl() {
        ssh_cp0 "KUBECONFIG=${constants.k8s.pkiDir}/admin-kubeconfig kubectl $*"
      }

      ceph_s_status() {
        # Pull `ceph -s --format json` and extract health.status.
        kctl -n "$CEPH_NS" exec deploy/rook-ceph-tools -- \
          ceph -s --format json 2>/dev/null \
          | sed -n 's/.*"status":"\(HEALTH_[A-Z_]*\)".*/\1/p' \
          | head -1
      }

      # ─── Resolve stop-one / start-one binaries (baked in at build) ────
      STOP_BIN="${vmScripts.stopOne}/bin/k8s-vm-stop-one"
      START_BIN="${vmScripts.startOne}/bin/k8s-vm-start-one"

      # ─── Cleanup: best-effort restart any dead VM at exit ────────────
      cleanup() {
        log "=== Cleanup ==="
        for n in cp0 cp1 cp2 w3; do
          if ! pgrep -x "k8s-$n" >/dev/null; then
            log "  $n is down, attempting restart..."
            "$START_BIN" --node="$n" || log "  (start $n failed)"
          fi
        done
      }
      trap cleanup EXIT INT TERM

      log "=== Warmup ($WARMUP s) ==="
      sleep "$WARMUP"

      wait_for_ceph_status() {
        local target="$1"
        local timeout="$2"
        local deadline=$(( SECONDS + timeout ))
        while (( SECONDS < deadline )); do
          if [[ "$(ceph_s_status)" = "$target" ]]; then return 0; fi
          sleep 5
        done
        return 1
      }

      wait_node_ready() {
        local node="$1"
        local timeout="$2"
        local deadline=$(( SECONDS + timeout ))
        while (( SECONDS < deadline )); do
          if kctl get node "k8s-$node" \
               -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
             | grep -q '^True$'; then
            return 0
          fi
          sleep 2
        done
        return 1
      }

      IFS=',' read -ra NODE_LIST <<< "$NODES"

      log "=== Pre-flight: waiting for HEALTH_OK ==="
      if ! wait_for_ceph_status "HEALTH_OK" 600; then
        log "ERROR: Ceph not HEALTH_OK after 10 min — aborting"
        exit 1
      fi
      log "Ceph is HEALTH_OK; starting chaos rounds"

      START_WALL="$(date +%s)"
      for r in $(seq 1 "$ROUNDS"); do
        for node in "''${NODE_LIST[@]}"; do
          log "── Round $r / $ROUNDS — node $node ──"

          PRE_STATUS="$(ceph_s_status || echo UNKNOWN)"
          log "  pre-kill ceph status: $PRE_STATUS"

          T0="$(date +%s.%N)"
          log "  KILL $node @ $T0"
          "$STOP_BIN" --node="$node"

          # Wait for HEALTH_WARN (the immediate symptom of OSD loss).
          if wait_for_ceph_status "HEALTH_WARN" 60; then
            T_WARN="$(date +%s.%N)"
            WARN_DELTA="$(echo "$T_WARN - $T0" | bc -l)"
            log "  ceph went HEALTH_WARN after $WARN_DELTA s"
          else
            T_WARN="$T0"
            WARN_DELTA="-1"
            log "  WARN: ceph did not flip to HEALTH_WARN within 60s"
          fi

          log "  START $node"
          "$START_BIN" --node="$node"

          log "  waiting for $node Ready (timeout 300s)..."
          if wait_node_ready "$node" 300; then
            T_REJOIN="$(date +%s.%N)"
            REJOIN_DELTA="$(echo "$T_REJOIN - $T0" | bc -l)"
            log "  $node Ready after $REJOIN_DELTA s"
          else
            T_REJOIN="$T0"
            REJOIN_DELTA="-1"
            log "  WARN: $node did not become Ready within 300s"
          fi

          # Wait for HEALTH_OK recovery (up to 5 min — OSD re-join takes ~30 s,
          # PG re-peer up to a couple minutes on a small cluster).
          if wait_for_ceph_status "HEALTH_OK" 300; then
            T_REC="$(date +%s.%N)"
            REC_DELTA="$(echo "$T_REC - $T0" | bc -l)"
            log "  ceph back to HEALTH_OK after $REC_DELTA s"
          else
            T_REC="$T0"
            REC_DELTA="-1"
            log "  ERROR: ceph not HEALTH_OK within 300s of kill"
          fi

          printf "%d\t%s\t%s\t%.3f\t%.3f\t%.3f\n" \
            "$r" "$node" "$PRE_STATUS" "$WARN_DELTA" "$REC_DELTA" "$REJOIN_DELTA" >> "$SUMMARY"

          log "  post-round wait: $POST_ROUND_WAIT s"
          sleep "$POST_ROUND_WAIT"

          ROUND_ELAPSED=$(( $(date +%s) - START_WALL ))
          EXPECTED=$(( (r - 1) * ''${#NODE_LIST[@]} * INTERVAL ))
          if (( ROUND_ELAPSED < EXPECTED )); then
            sleep $(( EXPECTED - ROUND_ELAPSED ))
          fi
        done
      done

      log "=== Summary ==="
      echo
      column -t -s $'\t' "$SUMMARY"
      echo
      echo "Recovery stats (seconds, only successful recoveries):"
      awk -F'\t' 'NR>1 && $5>=0 {
        n++; sum+=$5;
        if (min=="" || $5<min) min=$5;
        if (max=="" || $5>max) max=$5;
      }
      END {
        if (n==0) { print "  no successful recoveries"; exit }
        printf "  rounds: %d  min: %.3fs  mean: %.3fs  max: %.3fs\n",
          n, min, sum/n, max;
      }' "$SUMMARY"

      log "logs: $LOG_DIR/"
    '';
  };
}
