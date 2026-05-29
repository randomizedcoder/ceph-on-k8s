# ceph-on-k8s

A reproducible lab that demonstrates a **Rook-Ceph storage cluster on
Kubernetes** running on NixOS QEMU MicroVMs, plus an **external
NixOS client microvm** that mounts the cluster's CephFS from outside
the cluster — proving the storage is usable by anything on the lab
network, not just Kubernetes pods.

The whole thing — five virtual machines, the Kubernetes control plane,
the Ceph daemons, Cilium's CNI + BGP control plane, ArgoCD's GitOps,
cert-manager, the rendered manifests, every secret — is described in
Nix code under `nix/` and `nix/gitops/`. Two commands bring it up from
nothing; one command tears it down.

> A stripped-down, storage-focused sibling of
> [nix-k8s-examples](https://github.com/randomizedcoder/nix-k8s-examples).

## What this repo demonstrates

1. **A working Rook-Ceph cluster** with replicated block (RBD), shared
   file (CephFS), and S3 (RGW) all backed by a 4 × 10 GiB raw-device
   OSD pool spanning 4 nodes.
2. **An external CephFS client** (`client0`) that lives **outside**
   Kubernetes but on the same bridge — kernel `mount -t ceph` directly
   against the Ceph MONs, no CSI driver involved.
3. **A reproducible Nix-driven build** — VM images, rendered K8s
   manifests, host network setup, secret material, and per-node SSH
   host keys are all generated from one repo.
4. **Cilium eBPF networking** — kube-proxy replacement, Hubble flow
   observability, multi-pool IPAM, BGPControlPlane (peered with an
   optional FRR daemon on the host), L2 announce for LoadBalancer VIPs.
5. **GitOps drift control** — ArgoCD watches the `rendered/` directory
   in git, so changing a Nix file → `nix run .#k8s-render-manifests`
   → commit → ArgoCD applies.

## Architecture overview

```
                                  HOST
                          (NixOS + nix + qemu)
                                   │
   ┌───────────────────────────────┴───────────────────────────────┐
   │                       k8sbr0 (Linux bridge, 10.33.33.1/24)    │
   │   haproxy:6443 ── round-robin → cp0/cp1/cp2 :6443             │
   │   static route: 10.244.0.0/16 via 10.33.33.10                 │
   │   (optional) FRR bgpd  ← eBGP →  cilium-agent on each cp/w    │
   └──┬───────────┬───────────┬───────────┬────────────┬───────────┘
      │           │           │           │            │
   k8stap0     k8stap1     k8stap2     k8stap3      k8stap4
      │           │           │           │            │
  ┌───┴────┐ ┌────┴───┐ ┌─────┴──┐  ┌─────┴──┐   ┌────┴─────┐
  │ cp0    │ │ cp1    │ │ cp2    │  │ w3     │   │ client0  │
  │ .10    │ │ .11    │ │ .12    │  │ .13    │   │ .20      │
  │        │ │        │ │        │  │        │   │          │
  │ K8s CP │ │ K8s CP │ │ K8s CP │  │ Worker │   │ NOT a K8s│
  │ MON·MGR│ │ MON·MGR│ │ MON    │  │ OSD    │   │ node.    │
  │ OSD·MDS│ │ OSD·MDS│ │ OSD·RGW│  │        │   │ Kernel   │
  │        │ │        │ │        │  │        │   │ CephFS   │
  │ 10GiB  │ │ 10GiB  │ │ 10GiB  │  │ 8GiB   │   │ client.  │
  │ 4 vCPU │ │ 4 vCPU │ │ 4 vCPU │  │ 2 vCPU │   │ 2 GiB    │
  └────────┘ └────────┘ └────────┘  └────────┘   │ 2 vCPU   │
                                                  └──────────┘
```

Each cluster VM also has a dedicated **10 GiB raw block disk**
(`/dev/disk/by-id/virtio-ceph-osd-<hostname>`) that Rook claims
directly — no CSI / OpenEBS layer in between. The external client
microvm doesn't host any storage; it just consumes CephFS.

## Storage path

```
sparse file on host         host
   k8s-cp0-ceph.img          fs
        │
        └─ qemu virtio-blk ──┐
                             │
                       /dev/vdb           ─── guest kernel
                             │
                /dev/disk/by-id/
                virtio-ceph-osd-k8s-cp0   ─── stable by-id path
                             │
                             ▼
                  Rook ceph-volume raw      ─── direct device mode
                  prepare --bluestore        (no PVC, no StorageClass)
                             │
                             ▼
                  ceph-osd daemon (host net)
                             │
       ┌─────────────────────┼───────────────────────┐
       │                     │                       │
    RBD pool          CephFS pools           RGW pools
   replicapool   ceph-filesystem-data0      .rgw.*
                 ceph-filesystem-metadata
       │                     │                       │
       │              ceph-mds (MDS)            ceph-rgw (RGW)
       │                     │                       │
   StorageClass         StorageClass            S3 endpoint
   ceph-block           ceph-filesystem          (Ingress)
       │                     │
   PVC (RWO)            PVC (RWX) / kernel mount from client0
```

## What's deployed

| Component | Version | Purpose |
|-----------|---------|---------|
| Cilium | 1.19.3 | CNI, kube-proxy replacement, Hubble, ingress, L2 announce, BGPControlPlane, multi-pool IPAM |
| ArgoCD | 9.5.11 | GitOps controller; watches `rendered/` |
| cert-manager | v1.16.2 | TLS for the Ceph dashboard ingress |
| Rook-Ceph operator | v1.19.6 | Lifecycle controller for Ceph daemons |
| Rook-Ceph cluster | v1.19.6 | CephCluster: 3 MON · 2 MGR · 4 OSD · 2 MDS (1 active + 1 standby) · 1 RGW (all on hostNetwork) |
| ceph-external-client | n/a | A `ceph auth import` Job that registers `client.external` and a Secret the host-side flake reads to bake into `client0`'s `/etc/ceph` |
| ceph-demo | n/a | Pod that mounts an RBD PVC, a CephFS PVC, and writes to an S3 bucket — smoke test |

## Quick start

```bash
# 1. One-time host prep
nix run .#k8s-check-host             # verify tun / vhost-net / bridge / sudo
sudo nix run .#k8s-network-setup     # bridge + 5 TAPs + NAT + haproxy LB
                                     #   + static route to pod CIDR

# 2. Generate secrets (SSH host keys, user keypair, CephFS client keyring)
nix run .#k8s-gen-secrets            # idempotent; --force to rotate

# 3. Render the K8s manifests from Nix
nix run .#k8s-render-manifests       # writes rendered/

# 4. Build and boot all 4 cluster VMs (cold)
nix run .#k8s-start-all              # parallel boot, ~3 min to nodes Ready

# 5. Boot the external CephFS client (independent of the cluster)
nix run .#k8s-client-start

# 6. Verify
nix run .#k8s-vm-ssh -- --node=cp0 -- \
  "KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig kubectl get pods -A"
nix run .#k8s-vm-ssh -- --node=client0 -- 'mount | grep cephfs'
nix run .#k8s-vm-ssh -- --node=client0 -- 'df -h /mnt/cephfs'
```

To wipe everything:

```bash
nix run .#k8s-vm-stop     && nix run .#k8s-client-stop
nix run .#k8s-vm-wipe     && nix run .#k8s-client-wipe   # drop all disk images
sudo nix run .#k8s-network-teardown                       # bridge, TAPs, NAT, route
```

## Main components

### The cluster nodes (`cp0`/`cp1`/`cp2`/`w3`)

Defined by `nix/microvm.nix` (parametric NixOS-microvm generator) and
`nix/k8s-module.nix` (kube-apiserver/scheduler/controller-manager/etcd/
kubelet config). Each node:

- Has its sshd host key baked into the image at build time
  (no first-boot key generation, no TOFU).
- Has the K8s PKI baked in (CA + per-node server/client certs,
  generated by `nix run .#k8s-gen-certs`).
- Joins a single etcd cluster (cp0/cp1/cp2 are voting members).
- Runs Cilium as DaemonSet for CNI + load-balancing + ingress.

`cp0` additionally runs the **first-boot GitOps bootstrap**
(`nix/gitops-bootstrap-module.nix`): on first reboot it `kubectl
apply`s a small set of bootstrap-critical manifests baked into the
Nix store (Cilium install, ArgoCD install, the ArgoCD `Application`
CRs) — after which ArgoCD takes over and reconciles everything
else from `rendered/` in git.

### The external CephFS client (`client0`)

Defined by `nix/microvm-client.nix`. A minimal NixOS microvm with:

- The kernel `ceph` module loaded
- `bonnie++` in `systemPackages` for disk-I/O benchmarks
- A NixOS `fileSystems."/mnt/cephfs"` entry that mounts CephFS at boot
  with the CephX secret inlined into the mount options
- The same SSH hardening as the cluster nodes

It is **not** a Kubernetes node — no kubelet, no etcd, no kube-proxy.
It just demonstrates that the Ceph cluster exposes its storage to
the LAN, not only to Kubernetes pods.

### Cilium networking

- **CNI**: pod-to-pod traffic carried by Cilium's eBPF data plane.
- **kube-proxy replacement**: BPF-based service load balancing.
- **Ingress**: a single `cilium-ingress` LoadBalancer Service (VIP
  `10.33.33.50`) backs the Ceph dashboard and S3 endpoint via the
  built-in Envoy.
- **L2 announce**: ARP-advertises the LoadBalancer VIP range
  (`10.33.33.50–.54`) on the lab bridge.
- **Multi-pool IPAM**: two `CiliumPodIPPool`s — `default`
  (`10.244.0.0/18`) for regular pods, `ceph-mon-pool`
  (`10.244.99.0/29`) reserved for Ceph MONs (currently unused
  because Ceph runs on hostNetwork — kept in place for future
  experiments).
- **BGPControlPlane**: `CiliumBGPClusterConfig` + `PeerConfig` +
  `Advertisement` peer with FRR on the host (ASN 64512 cluster /
  64513 host). For now the host-side BGP is optional — a static
  `ip route add 10.244.0.0/16 via 10.33.33.10` installed by
  `k8s-network-setup` acts as a poor-person's BGP for the lab. See
  [`host-setup/frr-bgp.nix`](./host-setup/frr-bgp.nix) for the
  optional full BGP fragment.

### The Nix layer

- `flake.nix` — surface area: every command above is a `nix run
  .#<app-name>`.
- `nix/constants.nix` — single source of truth for IPs, MACs,
  ports, Helm chart pins, VM sizing, Ceph wiring, lifecycle
  timeouts.
- `nix/microvm.nix` + `nix/microvm-client.nix` — parametric NixOS
  microvm generators.
- `nix/microvm-scripts.nix` — flake apps for VM lifecycle
  (`k8s-vm-start-one`, `k8s-vm-stop-one`, `k8s-vm-wipe`,
  `k8s-vm-ssh`, …) + the equivalent client0 apps.
- `nix/secrets-gen.nix` + `nix/secrets.nix` — host-side secret
  generation; baked into images via Nix store paths.
- `nix/gitops/env/*.nix` — one file per app (`cilium.nix`,
  `rook-operator.nix`, `rook-cluster.nix`, `cert-manager.nix`,
  `argocd.nix`, `ceph-demo.nix`, `ceph-external-client.nix`,
  `base.nix`). Each emits a list of manifest files + an ArgoCD
  Application CR.
- `nix/gitops/default.nix` — entry point: collects all the env
  modules, runs Helm template on the ones that wrap Helm charts,
  writes the result to `rendered/`.

### The rendered manifests

`rendered/` is the contract between Nix and the cluster. ArgoCD
watches it in git (path-style Applications), the gitops-bootstrap
unit on cp0 also reads from `/var/lib/k8s-bootstrap/` (a tarball
embedded in the image). After editing any `nix/gitops/env/*.nix`:

```bash
nix run .#k8s-render-manifests   # regenerate
git add nix/ rendered/           # commit both together
git push
```

A fresh `nix run .#k8s-cluster-rebuild` is required to test
bootstrap-critical changes (Cilium, ArgoCD, base namespaces, Rook
operator, CephCluster) on a cold boot — they live in the VM image,
not in git.

## Operations cheat sheet

| Task | Command |
|------|---------|
| SSH into a VM | `nix run .#k8s-vm-ssh -- --node=cp0 -- <cmd>` |
| Run `kubectl` from cp0 | `... -- --node=cp0 -- 'KUBECONFIG=/var/lib/kubernetes/pki/admin-kubeconfig kubectl get pods -A'` |
| `ceph -s` from the toolbox | `... -- 'KUBECONFIG=… kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s'` |
| Rebuild VM images + cold boot | `nix run .#k8s-cluster-rebuild` |
| Lifecycle test one VM | `nix run .#k8s-lifecycle-test-cp0` |
| Chaos: kill + restore one CP | `nix run .#k8s-chaos-failover -- --rounds=5` |
| Re-render manifests | `nix run .#k8s-render-manifests` |
| Rotate secrets | `nix run .#k8s-gen-secrets -- --force` |

## Detailed design docs

- [`docs/ceph-design.md`](./docs/ceph-design.md) — full Ceph cluster
  design: storage stack layer-by-layer, daemon topology, pools, the
  external CephFS client, troubleshooting recipes.
- [`docs/nix-design.md`](./docs/nix-design.md) — how the Nix code
  is organized: secret/PKI flow, microvm parametrization, gitops
  rendering pipeline, the rendered-manifests pattern.
- [`host-setup/frr-bgp.nix`](./host-setup/frr-bgp.nix) — optional
  NixOS module fragment for running FRR on the host as a real BGP
  peer for the cluster (instead of the static route stand-in).

## Repo layout

```
.
├── README.md                         (this file)
├── flake.nix                         flake apps surface area
├── nix/
│   ├── constants.nix                 single source of truth
│   ├── microvm.nix                   cluster-node VM generator
│   ├── microvm-client.nix            external-client VM generator
│   ├── microvm-scripts.nix           VM lifecycle apps
│   ├── network-setup.nix             host bridge/TAP/route/haproxy
│   ├── k8s-module.nix                K8s services NixOS module
│   ├── gitops-bootstrap-module.nix   first-boot bootstrap unit
│   ├── secrets-gen.nix               generates secrets/
│   ├── secrets.nix                   reads secrets/, exposes to images
│   └── gitops/
│       ├── default.nix               manifest renderer
│       └── env/
│           ├── base.nix              namespaces + RBAC
│           ├── cilium.nix            Cilium + BGP + IPAM
│           ├── argocd.nix            ArgoCD self-hosting
│           ├── cert-manager.nix      cert-manager + lab CA
│           ├── rook-operator.nix     Rook operator chart
│           ├── rook-cluster.nix      CephCluster + pools + FS + RGW
│           ├── ceph-demo.nix         smoke-test workload
│           └── ceph-external-client.nix   client.external auth Job
├── rendered/                         (generated; ArgoCD source)
├── secrets/                          (generated; .gitignored content)
├── host-setup/
│   └── frr-bgp.nix                   optional host-side BGP peer
└── docs/
    ├── ceph-design.md
    └── nix-design.md
```
