# nix/constants.nix
#
# Shared constants for ceph-on-k8s MicroVM cluster infrastructure.
# All network params, serial ports, k8s CIDRs, cert config, lifecycle timeouts,
# Helm chart pins for the storage stack.
#
# Topology: 3 control planes (cp0, cp1, cp2) + 1 worker (w3)
#
rec {
  # ─── Node Configuration ──────────────────────────────────────────────
  # K8s cluster members. External Ceph clients live in clientNodeNames
  # below; they share the bridge but are NOT part of the cluster.
  nodeNames = [ "cp0" "cp1" "cp2" "w3" ];

  # External Ceph clients (NixOS microvms running outside Kubernetes,
  # consuming CephFS via the kernel client). The host's bridge/TAP
  # setup, SSH key infra, and known_hosts treat these the same as the
  # cluster nodes; only flake.nix and microvm-scripts.nix differ.
  clientNodeNames = [ "client0" ];

  # Convenience: every microvm name. Used by the host network setup
  # to enumerate TAPs and by secrets-gen.nix to enumerate host keys.
  allNodeNames = nodeNames ++ clientNodeNames;

  # ─── Network Configuration ──────────────────────────────────────────
  network = {
    bridge = "k8sbr0";

    # Per-node TAP devices. .20 is reserved for external client(s) so
    # the cluster range stays contiguous at .10–.13.
    taps = {
      cp0     = "k8stap0";
      cp1     = "k8stap1";
      cp2     = "k8stap2";
      w3      = "k8stap3";
      client0 = "k8stap4";
    };

    # Host bridge addresses (dual-stack)
    gateway4 = "10.33.33.1";
    gateway6 = "fd33:33:33::1";
    subnet4 = "10.33.33.0/24";
    subnet6 = "fd33:33:33::/64";

    # Per-node IP addresses
    ipv4 = {
      cp0     = "10.33.33.10";
      cp1     = "10.33.33.11";
      cp2     = "10.33.33.12";
      w3      = "10.33.33.13";
      client0 = "10.33.33.20";
    };
    ipv6 = {
      cp0     = "fd33:33:33::10";
      cp1     = "fd33:33:33::11";
      cp2     = "fd33:33:33::12";
      w3      = "fd33:33:33::13";
      client0 = "fd33:33:33::20";
    };

    # Per-node MAC addresses
    macs = {
      cp0     = "02:00:0a:21:21:10";
      cp1     = "02:00:0a:21:21:11";
      cp2     = "02:00:0a:21:21:12";
      w3      = "02:00:0a:21:21:13";
      client0 = "02:00:0a:21:21:20";
    };
  };

  # ─── Kubernetes Network CIDRs ──────────────────────────────────────
  k8s = {
    podCidr4 = "10.244.0.0/16";
    podCidr6 = "fd44:44:44::/48";
    serviceCidr4 = "10.96.0.0/12";
    serviceCidr6 = "fd96:96:96::/108";

    # First service IP (kubernetes.default)
    apiServiceIp = "10.96.0.1";

    # API endpoint via host-side load balancer (haproxy on bridge IP)
    apiEndpoint = "https://${network.gateway4}:6443";

    # DNS
    clusterDomain = "cluster.local";
    dnsServiceIp = "10.96.0.10";

    # PKI directory inside VMs
    pkiDir = "/var/lib/kubernetes/pki";

    # Cert output directory on host
    certDir = "./certs";
  };

  # ─── Serial Console Configuration ──────────────────────────────────
  # Each node gets 10 ports starting at base 25500.
  # +0 = serial (ttyS0), +1 = virtio (hvc0), +2-9 = reserved
  console = {
    portBase = 25500;
    serialOffset = 0;
    virtioOffset = 1;

    nodeBlocks = {
      cp0     = 0;    # 25500-25509
      cp1     = 10;   # 25510-25519
      cp2     = 20;   # 25520-25529
      w3      = 30;   # 25530-25539
      client0 = 40;   # 25540-25549
    };
  };

  # ─── VM Resources ──────────────────────────────────────────────────
  # Bumped from the source repo (8 GB CP / 6 GB worker) to fit Rook's
  # ~6 GB aggregate footprint plus headroom. Avoid exact powers of two
  # (QEMU hangs on some hosts).
  vm = {
    controlPlane = {
      memoryMB = 10239;  # 10 GB
      vcpus = 4;
    };
    worker = {
      memoryMB = 8191;   # 8 GB
      vcpus = 2;
    };
  };

  # ─── Observability ─────────────────────────────────────────────────
  nodeExporter = {
    port = 9100;
    listenAddress = "0.0.0.0";  # firewall disabled; bridge reachable
  };

  prometheus = {
    port = 9090;
    retentionTime = "15d";
    # Host that runs the Prometheus server (scrapes all nodes).
    host = "cp0";
  };

  grafana = {
    port = 3000;
    adminUser = "admin";
    adminPassword = "admin";  # test cluster — consistent with ssh password "k8s"
    secretKey = "SW2YcwTIb9zpOOhoPsMm";  # test cluster — legacy Grafana default
    # Pinned rfmoz/grafana-dashboards (Node Exporter Full dashboard).
    dashboardsRepo = {
      owner = "rfmoz";
      repo = "grafana-dashboards";
      rev = "fa9f41fa3efed31d5c2de73cd332a340797c0ec7";
      hash = "sha256-phqtDu/oLwqB+R+Dn9WyHyYbNcKR43uIy+F3BrAvwg4=";
    };
  };

  hubble = {
    uiNodePort    = 31234;  # Hubble UI (HTTP)
    relayNodePort = 31245;  # Hubble Relay gRPC (for `hubble` CLI)
    # Metrics ports live on cilium-agent's host network (hostNetwork=true).
    agentMetricsPort    = 9962;
    operatorMetricsPort = 9963;
    hubbleMetricsPort   = 9965;
  };

  # ─── Cilium Ingress + L2 announcements ─────────────────────────────
  # Cilium runs the cluster's only L7 proxy (Envoy). The built-in
  # ingress controller exposes a single LoadBalancer Service
  # (`cilium-ingress` in kube-system) whose IP is pulled from the
  # LoadBalancer IP pool below and advertised to the LAN via L2 ARP.
  #
  # The pool range covers 10.33.33.50–.54:
  #   .50 — cilium-ingress (shared HTTP/HTTPS ingress)
  #   .53 — Ceph MGR dashboard LB (reserved by ceph attrset)
  #   .54 — Ceph RGW S3 endpoint LB (reserved by ceph attrset)
  # MONs no longer use VIPs — they run hostNetwork (see ceph.monHosts).
  cilium = {
    ingress = {
      vip      = "10.33.33.50";
      vipStart = "10.33.33.50";
      vipStop  = "10.33.33.54";
      # VM-side NIC name on the K8s cluster nodes — the cilium agent
      # ARP-announces VIPs out of this interface. Cluster nodes have a
      # second virtio-blk (the ceph OSD disk) which bumps the PCI
      # numbering so the virtio-net lands at s5, not s4 (client0,
      # which has no second disk, sees its NIC as enp0s4 — but
      # client0 doesn't host L2 announce, only consumes VIPs).
      nic      = "enp0s5";
    };
  };

  # ─── Helm chart pins (rendered at Nix build time) ──────────────────
  # Update these by running:
  #   nix-prefetch-url --type sha256 <url>
  #   nix hash convert --hash-algo sha256 --to sri <raw>
  helmCharts = {
    cilium = {
      version = "1.19.3";
      url     = "https://helm.cilium.io/cilium-1.19.3.tgz";
      hash    = "sha256-yOBd+eq/kBnmL1ED4fNYFLTxtDkW+IUZ5a5ONsaapCs=";
    };
    argocd = {
      version = "9.5.11";  # appVersion v3.3.9 — fixes GHSA-3v3m-wc6v-x4x3 (secret extraction via ServerSideDiff)
      url     = "https://github.com/argoproj/argo-helm/releases/download/argo-cd-9.5.11/argo-cd-9.5.11.tgz";
      hash    = "sha256-TyvlRDv3PifSR0mcO/un/24CJo2UzIBHeu8j4a6osB8=";
    };
    rookCephOperator = {
      version = "v1.19.6";
      url     = "https://charts.rook.io/release/rook-ceph-v1.19.6.tgz";
      hash    = "sha256-NKNNRI1L5XmY2BF/6eWQh0n2/pqmxsYYRLv7hdz6LWs=";
    };
    rookCephCluster = {
      version = "v1.19.6";
      url     = "https://charts.rook.io/release/rook-ceph-cluster-v1.19.6.tgz";
      hash    = "sha256-KKBF8HG+GQGWWH5PWugYC/0nvxl0tpmMGUZPpTvp1Vk=";
    };
  };

  # ─── cert-manager (static installer) ───────────────────────────────
  certManager = {
    version = "v1.16.2";
    url  = "https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml";
    hash = "sha256-HVHN7NRC8fX4l4Pp4BabldNyck2iA8x13XpcTlChDOY=";
  };

  # ─── Ceph cluster wiring ──────────────────────────────────────────
  # OSD storage backing: Rook consumes the raw 10 GiB disk on each
  # node directly via `storage.nodes[].devices` in the CephCluster CR.
  # We tried OpenEBS device-localpv first, but the project is
  # archived and its v0.9.0 agent requires a non-trivial
  # meta-partition scheme that's poorly documented. Direct device
  # discovery is the canonical Rook pattern and works without an
  # intermediate CSI layer; the `ceph-disk-init` oneshot in
  # k8s-module.nix just wipes any filesystem header so Rook's
  # `ceph-volume` can take the disk fresh.
  ceph = {
    namespace = "rook-ceph";
    osd = {
      diskSizeGi    = 10;          # per-node raw disk (lab-only; bump for real use)
      perNodeCount  = 1;
      sizeGiPerOsd  = 10;
      # By-id path that Rook's CephCluster `nodes[].devices` references;
      # the virtio-blk serial we set in microvm.nix produces this name.
      devicePath = "/dev/disk/by-id/virtio-ceph-osd-";  # suffix per-host hostname
    };
    dashboard = { host = "ceph.lab.local"; vip = "10.33.33.53"; };
    rgw       = { host = "s3.lab.local";   vip = "10.33.33.54"; };

    # MONs run on hostNetwork (cephClusterSpec.network.provider=host)
    # so each MON daemon binds to and advertises its node's actual IP
    # (10.33.33.10/11/12) on port 6789 (msgr-v1) / 3300 (msgr2). The
    # alternative — LoadBalancer Services + Cilium L2 announce — runs
    # into a Ceph design constraint: MONs put their advertised address
    # in the MON map, which on regular pod networking is the pod IP
    # (10.x.x.x), and the kernel client rejects connections where the
    # actual peer IP doesn't match the advertised one ("wrong peer at
    # address"). hostNetwork bypasses the whole problem.
    #
    # External clients (e.g. client0) mount with this list:
    monHosts = [
      "${network.ipv4.cp0}:6789"
      "${network.ipv4.cp1}:6789"
      "${network.ipv4.cp2}:6789"
    ];

    # External CephFS user that the client0 microvm uses to mount
    # the filesystem. The keyring is pre-generated by
    # k8s-gen-secrets and applied to the cluster by the
    # ceph-external-client env module's Job.
    externalClient = {
      user     = "external";   # CephX user name (full name: client.external)
      fsName   = "ceph-filesystem";
      mountDir = "/mnt/cephfs";
    };
  };

  # ─── ArgoCD service (NodePort reachable from host) ─────────────────
  argocd = {
    nodePortHttps = 30443;
  };

  # ─── Chaos / failover test defaults ────────────────────────────────
  chaos = {
    defaultRounds         = 10;
    defaultIntervalSec    = 60;
    defaultPostRoundWait  = 60;
    defaultWarmupSec      = 15;
    defaultLogDir         = "./chaos-logs";
  };

  # ─── SSH Configuration ─────────────────────────────────────────────
  # Key-based auth only. Password and keyboard-interactive auth are
  # disabled in sshd; host keys are baked into the VM image at build
  # time from ./secrets/host-keys/ (see nix/secrets.nix). The host's
  # known_hosts is pre-populated with the matching pubkeys so no
  # TOFU / StrictHostKeyChecking=no is needed.
  ssh = {
    user = "root";
  };

  # ─── Lifecycle Test Configuration ──────────────────────────────────
  lifecycle = {
    pollInterval = 1;

    timeouts = {
      build = 900;
      processStart = 5;
      serialReady = 30;
      virtioReady = 45;
      sshReady = 90;
      certInject = 30;
      serviceReady = 90;
      k8sHealth = 90;
      shutdown = 30;
      waitExit = 60;
    };

    # Cluster-level test timeouts
    clusterTimeouts = {
      nodesReady = 180;
      ciliumReady = 120;
      workloadsReady = 120;
    };
  };

  # ─── GitOps Configuration ────────────────────────────────────────────
  gitops = {
    repoURL = "https://github.com/randomizedcoder/ceph-on-k8s.git";
    targetRevision = "main";
    renderedPath = "rendered";
  };

  # ─── Helper Functions ──────────────────────────────────────────────

  # Get console ports for a node
  getConsolePorts = node: {
    serial = console.portBase + console.nodeBlocks.${node} + console.serialOffset;
    virtio = console.portBase + console.nodeBlocks.${node} + console.virtioOffset;
  };

  # Get hostname for a node
  getHostname = node: "k8s-${node}";

  # Get process name for pgrep matching
  getProcessName = node: getHostname node;

  # Get timeout for a phase (no per-node overrides for now)
  getTimeout = _node: phase: lifecycle.timeouts.${phase};

  # Get all node IPv4 addresses as a list
  allNodeIps4 = builtins.map (n: network.ipv4.${n}) nodeNames;

  # Get all node IPv6 addresses as a list
  allNodeIps6 = builtins.map (n: network.ipv6.${n}) nodeNames;

  # Get VM resources for a role
  getVmResources = role:
    if role == "control-plane" then vm.controlPlane
    else vm.worker;
}
