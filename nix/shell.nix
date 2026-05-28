# nix/shell.nix
#
# Development shell for ceph-on-k8s cluster.
#
{ pkgs }:
pkgs.mkShell {
  packages = with pkgs; [
    # ─── Kubernetes ──────────────────────────────────────────────────
    kubectl
    kubernetes-helm
    cilium-cli
    hubble
    argocd
    step-cli
    # ─── Storage / Ceph ──────────────────────────────────────────────
    # `ceph` CLI is not in the dev shell — its Python deps clash with
    # the current nixpkgs. Run it from inside the cluster instead:
    #   kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph -s
    minio-client  # `mc` — S3 client for talking to the RGW endpoint
    # ─── Infra / debug ───────────────────────────────────────────────
    socat
    expect
    jq
    nftables
    iproute2
    curl
    openssl
  ];
  shellHook = ''
    echo "ceph-on-k8s Development Shell (3 CP + 1 Worker + Rook-Ceph)"
    echo ""
    echo "Quick start:"
    echo "  nix run .#k8s-check-host             # Verify host prereqs"
    echo "  sudo nix run .#k8s-network-setup     # Create network + haproxy LB"
    echo "  nix run .#k8s-gen-secrets            # Generate SSH keypair"
    echo "  nix run .#k8s-render-manifests       # Render Helm charts"
    echo "  nix run .#k8s-start-all              # Build + start all VMs"
    echo "  nix run .#k8s-vm-ssh -- --node=cp0   # SSH to cp0"
    echo ""
    echo "See docs/ceph-design.md and docs/nix-design.md for the design."
  '';
}
