# nix/lifecycle/k8s-checks.nix
#
# K8s verification helpers for lifecycle testing.
# etcd health, apiserver /healthz, node readiness.
#
{ pkgs, lib }:
let
  mainConstants = import ../constants.nix;

  sshOpts = lib.concatStringsSep " " [
    "-o" "StrictHostKeyChecking=no"
    "-o" "UserKnownHostsFile=/dev/null"
    "-o" "ConnectTimeout=5"
    "-o" "LogLevel=ERROR"
    "-o" "PubkeyAuthentication=no"
  ];
in
{
  # Check if a service is active on a node via SSH
  mkCheckServiceScript = ''
    check_service() {
      local host="$1"
      local service="$2"
      sshpass -p ${mainConstants.ssh.password} ssh ${sshOpts} \
        "root@$host" "systemctl is-active $service" 2>/dev/null | grep -q "^active$"
    }

    wait_for_service() {
      local host="$1"
      local service="$2"
      local timeout="$3"
      local elapsed=0
      while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(sshpass -p ${mainConstants.ssh.password} ssh ${sshOpts} \
          "root@$host" "systemctl is-active $service" 2>/dev/null || echo "unknown")
        case "$status" in
          active) return 0 ;;
          failed) return 1 ;;
          *) sleep 1; elapsed=$((elapsed + 1)) ;;
        esac
      done
      return 1
    }
  '';

  # Check etcd health via SSH
  mkCheckEtcdScript = ''
    check_etcd_health() {
      local host="$1"
      sshpass -p ${mainConstants.ssh.password} ssh ${sshOpts} \
        "root@$host" "etcdctl --endpoints=https://127.0.0.1:2379 \
          --cacert=/var/lib/kubernetes/pki/etcd-ca.crt \
          --cert=/var/lib/kubernetes/pki/etcd-server.crt \
          --key=/var/lib/kubernetes/pki/etcd-server.key \
          endpoint health" 2>/dev/null | grep -q "is healthy"
    }
  '';

  # Check apiserver health via SSH
  mkCheckApiserverScript = ''
    check_apiserver_health() {
      local host="$1"
      sshpass -p ${mainConstants.ssh.password} ssh ${sshOpts} \
        "root@$host" "curl -sk https://127.0.0.1:6443/healthz" 2>/dev/null | grep -q "ok"
    }
  '';

  # Check etcd quorum (member count) via SSH
  mkCheckEtcdQuorumScript = ''
    check_etcd_quorum() {
      local host="$1"
      local expected="$2"
      local count
      count=$(sshpass -p ${mainConstants.ssh.password} ssh ${sshOpts} \
        "root@$host" "etcdctl --endpoints=https://127.0.0.1:2379 \
          --cacert=${mainConstants.k8s.pkiDir}/etcd-ca.crt \
          --cert=${mainConstants.k8s.pkiDir}/etcd-server.crt \
          --key=${mainConstants.k8s.pkiDir}/etcd-server.key \
          member list" 2>/dev/null | wc -l)
      [[ "$count" -ge "$expected" ]]
    }
  '';

  # Check all nodes Ready via kubectl
  mkCheckNodesReadyScript = ''
    check_nodes_ready() {
      local host="$1"
      local expected="$2"
      local count
      count=$(sshpass -p ${mainConstants.ssh.password} ssh ${sshOpts} \
        "root@$host" "kubectl --kubeconfig=${mainConstants.k8s.pkiDir}/admin-kubeconfig \
          get nodes --no-headers 2>/dev/null | grep -c ' Ready '" 2>/dev/null | tail -1)
      count="''${count:-0}"
      [[ "$count" -ge "$expected" ]]
    }
  '';

  # Check Rook-Ceph cluster health: HEALTH_OK and ${expectedOsds} OSDs up,in
  # via `kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph -s`.
  # Used as the storage-tier gate in the lifecycle cluster test.
  mkCheckCephHealthyScript = ''
    check_ceph_healthy() {
      local host="$1"
      local expected_osds="$2"
      local out
      out=$(sshpass -p ${mainConstants.ssh.password} ssh ${sshOpts} \
        "root@$host" "KUBECONFIG=${mainConstants.k8s.pkiDir}/admin-kubeconfig \
          kubectl -n ${mainConstants.ceph.namespace} exec deploy/rook-ceph-tools \
          -- ceph -s --format json" 2>/dev/null)
      if [[ -z "$out" ]]; then
        return 1
      fi
      # Parse health.status and osdmap.num_up_osds out of `ceph -s --format json`.
      # Avoids jq dependency on the host by using awk.
      local health up in
      health=$(echo "$out" | sed -n 's/.*"status":"\(HEALTH_[A-Z_]*\)".*/\1/p' | head -1)
      up=$(echo "$out" | sed -n 's/.*"num_up_osds":\([0-9]*\).*/\1/p' | head -1)
      in=$(echo "$out" | sed -n 's/.*"num_in_osds":\([0-9]*\).*/\1/p' | head -1)
      [[ "$health" = "HEALTH_OK" ]] && \
        [[ "''${up:-0}" -ge "$expected_osds" ]] && \
        [[ "''${in:-0}"  -ge "$expected_osds" ]]
    }

    wait_for_ceph_healthy() {
      local host="$1"
      local expected_osds="$2"
      local timeout="$3"
      local elapsed=0
      while [[ $elapsed -lt $timeout ]]; do
        if check_ceph_healthy "$host" "$expected_osds"; then
          return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
      done
      return 1
    }
  '';

  # SSH helper
  mkSshHelper = ''
    ssh_cmd() {
      local host="$1"
      shift
      sshpass -p ${mainConstants.ssh.password} ssh ${sshOpts} \
        "root@$host" "$@" 2>/dev/null
    }

    wait_for_ssh() {
      local host="$1"
      local timeout="$2"
      local elapsed=0
      while [[ $elapsed -lt $timeout ]]; do
        if sshpass -p ${mainConstants.ssh.password} ssh ${sshOpts} \
          "root@$host" true 2>/dev/null; then
          return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
      done
      return 1
    }
  '';
}
