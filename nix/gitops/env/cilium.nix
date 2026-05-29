# nix/gitops/env/cilium.nix
#
# Cilium — rendered-manifests pattern.
#
# At Nix build time: `helm template` is run against the pinned Cilium chart
# tarball with the values below. The result is written to
# rendered/cilium/install.yaml as plain YAML (CRDs included).
# ArgoCD reads that directory via a path-source Application — no in-cluster
# Helm templating.
#
# For the first-boot bootstrap, `install.yaml` is also applied directly by
# the gitops-bootstrap systemd unit on cp0 (since we need Cilium up before
# ArgoCD can sync anything).
#
{ pkgs, lib, helm }:
let
  constants = import ../../constants.nix;

  valuesYaml = ''
    # Cilium Helm values — rendered at Nix build time.
    kubeProxyReplacement: true
    k8sServiceHost: "${constants.network.gateway4}"
    k8sServicePort: "6443"

    # ─── IPAM: multi-pool ─────────────────────────────────────────
    # Each pool is a CIDR slice that Cilium operator allocates from.
    # Pods request a pool via annotation `ipam.cilium.io/ip-pool`;
    # un-annotated pods land in `default`. The `ceph-mon` pool exists
    # to pin Ceph MON pods to a small, deterministic range so external
    # CephFS clients have a stable bootstrap list (see
    # constants.ceph.monHosts + rook-cluster.nix annotations.mon).
    # The pool CIDRs are BGP-advertised to the host so external clients
    # (e.g. client0) can route directly to MON pod IPs — sidestepping
    # the "wrong peer at address" mismatch that LB VIPs hit, because
    # each MON now advertises its actual pinned pod IP in the MON map.
    ipam:
      mode: multi-pool
      operator:
        autoCreateCiliumPodIPPools:
          # 10.244.0.0/18 (16 K IPs, /24 per node). Non-overlapping
          # with the ceph-mon pool below — see the constants.nix
          # comment on monPoolCidr.
          default:
            ipv4:
              cidrs:
                - "10.244.0.0/18"
              maskSize: 24
          # /29 (8 IPs, /32 per pod) — Cilium picks 3 from .1..6 for
          # the 3 MONs. constants.ceph.monHosts lists every usable IP
          # in this CIDR so the kernel client can bootstrap regardless
          # of which IP a MON landed on. Name must match the
          # `ipam.cilium.io/ip-pool` annotation set on the MON pod
          # template by rook-cluster.nix.
          ceph-mon-pool:
            ipv4:
              cidrs:
                - "10.244.99.0/29"
              maskSize: 32

    # IPv6 disabled under multi-pool: we'd need a per-pool v6 CIDR for
    # every pool; not worth the complexity for the lab.
    ipv4:
      enabled: true
    ipv6:
      enabled: false

    bpf:
      masquerade: true

    # ─── BGP control plane ───────────────────────────────────────
    # Replaces L2 announce for the pod-CIDR advertisement (L2 announce
    # is kept for the LoadBalancer Services). Each cilium-agent peers
    # with FRR on the host (10.33.33.1) and announces the local node's
    # pod-IP slice (per-node /24 of the default pool + per-MON /32 of
    # the ceph-mon pool). See cilium-bgp-*.yaml manifests below.
    bgpControlPlane:
      enabled: true

    # ─── Hubble: flow visibility, UI, metrics ───────────────────────
    hubble:
      enabled: true
      # Test env — mTLS disabled so `hubble` CLI from host just works.
      tls:
        enabled: false
      peerService:
        enabled: true
      relay:
        enabled: true
        startupProbe:
          failureThreshold: 40
        service:
          type: NodePort
          nodePort: ${toString constants.hubble.relayNodePort}
      ui:
        enabled: true
        service:
          type: NodePort
          nodePort: ${toString constants.hubble.uiNodePort}
      metrics:
        enableOpenMetrics: true
        enabled:
          - dns
          - drop
          - tcp
          - flow
          - port-distribution
          - icmp
          - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"

    # ─── Expose cilium-agent + operator Prometheus endpoints ────────
    prometheus:
      enabled: true
      port: ${toString constants.hubble.agentMetricsPort}

    operator:
      replicas: 1
      prometheus:
        enabled: true
        port: ${toString constants.hubble.operatorMetricsPort}
      resources:
        requests:
          cpu: 50m
          memory: 128Mi

    resources:
      requests:
        cpu: 100m
        memory: 256Mi

    # ─── Ingress (replaces ingress-nginx) ───────────────────────────
    # Cilium's built-in Envoy serves the cluster's Ingress objects.
    # Exposed through a single LoadBalancer Service (`cilium-ingress`
    # in kube-system) whose ExternalIP is assigned from the
    # CiliumLoadBalancerIPPool below and advertised on the LAN via L2
    # ARP announcements. Phase-2: swap l2announcements → bgpControlPlane,
    # same VIP, same Service, same Ingress — no further rewrite.
    ingressController:
      enabled: true
      default: true              # make "cilium" the default IngressClass
      loadbalancerMode: shared   # one cilium-ingress Service for all Ingresses
      enforceHttps: false        # redirect at the app layer if needed
      service:
        type: LoadBalancer

    # ─── L2 announcements (LAN-scoped VIP advertisement) ────────────
    # Needed for the LoadBalancer Service above to actually be
    # reachable from the host without a real cloud LB. Cilium elects a
    # single agent to ARP-reply for the VIP; on node loss another takes
    # over (see chaos-failover test).
    l2announcements:
      enabled: true

    # L2 announcements talk to the K8s API a lot (leases for VIP
    # ownership). Bump the client-side QPS/burst per Cilium docs to
    # avoid throttling with a small cluster + tight leases.
    k8sClientRateLimit:
      qps: 10
      burst: 20
  '';

  rendered = helm.renderChart {
    name        = "cilium";
    releaseName = "cilium";
    namespace   = "kube-system";
    chart       = constants.helmCharts.cilium;
    values      = valuesYaml;
  };
in
{
  manifests = [
    # Fully-rendered multi-doc YAML from `helm template`.
    {
      name = "cilium/install.yaml";
      source = "${rendered}/install.yaml";
    }
    # Audit copy of the values used at render time.
    {
      name = "cilium/values.yaml";
      content = valuesYaml;
    }
    # ─── LoadBalancer IP pool for cilium-ingress + Ceph LBs ──────────
    # Kept as raw YAML (not Helm-templated) so the pool/policy are
    # co-located with the module that enables the feature. The range
    # covers cilium-ingress (.50) + the dashboard/RGW/MON LBs added by
    # rook-cluster.nix (.53–.57). See constants.cilium.ingress comment.
    {
      name = "cilium/lb-ip-pool.yaml";
      content = ''
        # v2 is stable for CiliumLoadBalancerIPPool in 1.19; policy below
        # stays at v2alpha1 because CiliumL2AnnouncementPolicy hasn't
        # graduated yet.
        apiVersion: cilium.io/v2
        kind: CiliumLoadBalancerIPPool
        metadata:
          name: lab-lb-pool
          # No sync-wave — must land in the same wave as install.yaml
          # (wave 0). Otherwise ArgoCD blocks waiting for the
          # cilium-ingress Service to become healthy before applying
          # the pool that assigns its LoadBalancerIP. Circular dep.
        spec:
          blocks:
          - start: "${constants.cilium.ingress.vipStart}"
            stop:  "${constants.cilium.ingress.vipStop}"
      '';
    }
    # ─── L2 announcement policy (cilium-ingress only) ─────────────────
    # Cilium labels the auto-created cilium-ingress Service with
    # `cilium.io/ingress: "true"` (confirmed in the rendered install.yaml).
    # Scoping the selector to that label means we only ARP-announce the
    # ingress VIP here. The Ceph MON LB Services have their own
    # `lab-l2-rook` policy added by nix/gitops/env/rook-cluster.nix —
    # keeping them separate so cilium-ingress is unaffected if rook
    # is wiped.
    # The interface name is the VM-side NIC (verified via `ip -br link`
    # on cp0: enp0s4, the virtio-net device cloud-init renames to).
    {
      name = "cilium/l2-announcement-policy.yaml";
      content = ''
        apiVersion: cilium.io/v2alpha1
        kind: CiliumL2AnnouncementPolicy
        metadata:
          name: lab-l2
          # Same wave as lb-ip-pool.yaml (wave 0): the pool feeds the
          # Service EXTERNAL-IP, the policy makes that IP ARP-reachable.
          # ArgoCD won't mark the Service healthy without both.
        spec:
          serviceSelector:
            matchLabels:
              cilium.io/ingress: "true"
          interfaces:
          - ${constants.cilium.ingress.nic}
          externalIPs: true
          loadBalancerIPs: true
      '';
    }
    # ─── BGP control plane: peer with FRR on host (10.33.33.1) ────
    # eBGP between cluster (ASN 64512) and host (ASN 64513). Each
    # cilium-agent on a node opens a TCP session to the host's bgpd
    # and advertises whatever pod-IP slice that node has been
    # allocated by the multi-pool IPAM operator.
    {
      name = "cilium/bgp-cluster-config.yaml";
      content = ''
        apiVersion: cilium.io/v2
        kind: CiliumBGPClusterConfig
        metadata:
          name: lab-bgp-cluster
        spec:
          # Every Linux node in the cluster participates in BGP.
          nodeSelector:
            matchLabels:
              kubernetes.io/os: linux
          bgpInstances:
          - name: lab-instance
            localASN: 64512
            peers:
            - name: host-frr
              peerASN: 64513
              peerAddress: ${constants.network.gateway4}
              peerConfigRef:
                name: lab-bgp-peer
      '';
    }
    {
      name = "cilium/bgp-peer-config.yaml";
      content = ''
        apiVersion: cilium.io/v2
        kind: CiliumBGPPeerConfig
        metadata:
          name: lab-bgp-peer
        spec:
          timers:
            holdTimeSeconds: 30
            keepAliveTimeSeconds: 10
          gracefulRestart:
            enabled: true
            restartTimeSeconds: 120
          families:
          - afi: ipv4
            safi: unicast
            advertisements:
              matchLabels:
                advertise: bgp
      '';
    }
    {
      name = "cilium/bgp-advertisement.yaml";
      content = ''
        apiVersion: cilium.io/v2
        kind: CiliumBGPAdvertisement
        metadata:
          name: lab-bgp-advert
          labels:
            advertise: bgp
        spec:
          advertisements:
          # Advertise every pod-IP pool the node has a slice of (both
          # `default` and `ceph-mon`). Cilium computes the actual
          # per-node prefix at agent runtime; the host sees a /24 per
          # node for `default` and a /32 per MON node for `ceph-mon`.
          - advertisementType: CiliumPodIPPool
      '';
    }
    # Path-source Application — ArgoCD applies install.yaml and ignores the
    # Application CR file itself (directory.exclude).
    {
      name = "cilium/application.yaml";
      content = ''
        apiVersion: argoproj.io/v1alpha1
        kind: Application
        metadata:
          name: cilium
          namespace: argocd
        spec:
          project: default
          source:
            repoURL: ${constants.gitops.repoURL}
            targetRevision: ${constants.gitops.targetRevision}
            path: ${constants.gitops.renderedPath}/cilium
            directory:
              recurse: false
              exclude: '{application.yaml,values.yaml}'
          destination:
            server: https://kubernetes.default.svc
            namespace: kube-system
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
            syncOptions:
              - ServerSideApply=true
              - CreateNamespace=true
      '';
    }
  ];
}
