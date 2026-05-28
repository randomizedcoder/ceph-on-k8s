# ceph-on-k8s

A reproducible 4-node Kubernetes lab — 3 control planes + 1 worker —
running as NixOS QEMU MicroVMs on a single host, with **Rook-Ceph**
storage backed by **OpenEBS Local PV Device** on a dedicated 10 GiB raw
block disk per VM. CNI is **Cilium** (eBPF, kube-proxy replaced),
networking is dual-stack IPv4/IPv6, apiserver HA via host-side haproxy.

> This is a stripped-down, storage-focused sibling of
> [nix-k8s-examples](https://github.com/randomizedcoder/nix-k8s-examples).
> See [`docs/ceph-design.md`](./docs/ceph-design.md) for the Ceph cluster
> design and [`docs/nix-design.md`](./docs/nix-design.md) for the Nix
> code organization.

## Architecture

```
  Host ─── k8sbr0 (bridge) ─┬─ k8stap0 → cp0  10.33.33.10  (MON + MGR + OSD)
           haproxy:6443 ──┐  ├─ k8stap1 → cp1  10.33.33.11  (MON + MGR + OSD)
           (LB → 3 CPs)  │  ├─ k8stap2 → cp2  10.33.33.12  (MON + OSD)
                          └──└─ k8stap3 → w3   10.33.33.13  (OSD)
```

Each VM has two block devices: a 20 GiB `${hostname}-data.img` mounted
at `/var/lib` (etcd, kubelet, containerd) plus a 10 GiB
`${hostname}-ceph.img` exposed as raw `/dev/vdb` for OpenEBS NDM to
claim and Rook to consume as a PVC-based OSD.

## What's deployed

- **Cilium 1.19.3** — CNI + L2 ingress + Hubble
- **ArgoCD 9.5.11** — GitOps controller for `rendered/`
- **cert-manager v1.16.2** — TLS issuance from an in-cluster CA
- **OpenEBS Local PV Device** — discovers `/dev/vdb`, exposes
  `openebs-device` raw-block StorageClass *(task #4)*
- **Rook-Ceph operator v1.19.x** — CSI plugins on every node *(task #5)*
- **CephCluster** — 3 MONs · 2 MGRs · 4 OSDs · 3 MDSs · 2 RGWs;
  pools backed by replication factor 3 across the `host` failure domain
  *(task #6)*
- **Ceph dashboard** + **RGW S3** via Cilium L2-announced VIPs
  *(task #7)*
- **ceph-demo** workload — 1 RWO + 1 RWX + 1 S3 bucket *(task #8)*

## Quick start

```bash
# Host prereqs (one-time)
nix run .#k8s-check-host             # verify tun/vhost-net/bridge
sudo nix run .#k8s-network-setup     # bridge + 4 TAPs + NAT + haproxy LB

# Per-cluster
nix run .#k8s-gen-secrets            # SSH keypair → ./secrets/
nix run .#k8s-render-manifests       # Helm template → ./rendered/

# Boot
nix run .#k8s-start-all              # 4 VMs come up; bootstrap runs on cp0

# Inspect
nix run .#k8s-vm-ssh -- --node=cp0 kubectl get pods -A
nix run .#k8s-vm-ssh -- --node=cp0 \
  kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph -s
```

## Teardown

```bash
nix run .#k8s-vm-stop                # stop all VMs
sudo nix run .#k8s-network-teardown  # remove bridge/TAPs/NAT/haproxy
nix run .#k8s-vm-wipe                # delete *-data.img and *-ceph.img
```

## Storage math

```
  Raw capacity     : 4 nodes × 10 GiB = 40 GiB
  Useable (3 reps) : 40 / 3 ≈ 13 GiB
  Practical        : ≈ 10 GiB after Ceph's ~20% near-full reserve
```

10 GiB/OSD is below the production Bluestore minimum (~5 GiB metadata
overhead per OSD). Sufficient for proving the configuration end-to-end
with the small demo workload but **not** for any real workload — scaling
up is a one-line change in `nix/constants.nix` (`ceph.osd.diskSizeGi`).

## Source repo

This repo started as a copy of
[nix-k8s-examples](https://github.com/randomizedcoder/nix-k8s-examples)
with all the matrix/tidb/foundationdb/clickhouse/cnpg/forgejo/anubis/
nginx-demo/pdns/zot/hubble-otel modules removed and Ceph-focused modules
added. The microvm runtime, host network setup, build-time PKI, k8s
module, and gitops-bootstrap module are reused verbatim.

## License

See [`LICENSE`](./LICENSE).
