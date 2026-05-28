# Project: ceph-on-k8s

A 4-node NixOS MicroVM Kubernetes cluster (3 CP + 1 worker) running
Rook-Ceph on top of OpenEBS Local PV Device. Read `docs/ceph-design.md`
and `docs/nix-design.md` for the full design.

## VM Access

Full root SSH access to all 4 MicroVMs via the pre-generated SSH key:

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -i secrets/ssh-ed25519 root@<IP> '<command>'
```

| Node | IP |
|------|----|
| cp0 | 10.33.33.10 |
| cp1 | 10.33.33.11 |
| cp2 | 10.33.33.12 |
| w3  | 10.33.33.13 |

For kubectl commands via SSH, always set KUBECONFIG:

```bash
ssh -i secrets/ssh-ed25519 root@10.33.33.10 \
  'KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig kubectl get pods -A'
```

For Ceph CLI debugging:

```bash
ssh -i secrets/ssh-ed25519 root@10.33.33.10 \
  'KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph -s'
```

## Rendered Manifests Workflow

After changing any Nix gitops source (`nix/gitops/env/*.nix`):

```bash
nix run .#k8s-render-manifests   # regenerate rendered/ from Nix
# commit both nix/ and rendered/ changes together
```

ArgoCD watches the `rendered/` directory in git, not the Nix source.
The bootstrap-critical manifests (Cilium, base, cert-manager, OpenEBS,
Rook operator, CephCluster) are also baked into the VM image via the
Nix store and applied by the cp0 first-boot systemd oneshot — so a
fresh `nix run .#k8s-cluster-rebuild` after editing them is required
to test changes on cold boot.

## Secrets

Secrets live in `./secrets/` (git-staged, not committed). Generate with:

```bash
nix run .#k8s-gen-secrets          # first time
nix run .#k8s-gen-secrets -- --force  # rotate
```

This repo only generates the SSH keypair (the source repo's
matrix/anubis/observability/registry/pdns/forgejo secret generation has
been removed). Rook generates its own dashboard admin password.

## Key Patterns

- **Bootstrap module**: `nix/gitops-bootstrap-module.nix` — runs on cp0
  first boot, applies manifests in order (Cilium → CoreDNS → ArgoCD →
  OpenEBS → Rook → CephCluster → Apps).
- **Constants**: `nix/constants.nix` — all IPs, ports, image versions,
  Helm chart pins, ceph wiring.
- **Storage stack**: see `docs/ceph-design.md` for layer-by-layer detail
  from sparse host file → virtio-blk → OpenEBS PV → Rook OSD → pools →
  StorageClasses.

## Plan

The implementation plan lives at
`/home/das/.claude/profiles/personal/plans/o-curried-toucan.md`. Steps
not yet completed are tracked in the in-repo task list.
