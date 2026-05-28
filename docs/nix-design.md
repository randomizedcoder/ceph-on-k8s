# Nix design

This document describes how the ceph-on-k8s repository is organized as Nix
code. It explains the rendered-manifest pattern inherited from the source
repo `nix-k8s-examples`, the module layout, the build and bootstrap flow,
and how each layer of the storage stack maps to a Nix file.

It does **not** describe the Ceph cluster itself; see
[`ceph-design.md`](./ceph-design.md) for that.

## Goals and constraints

- **Reproducible builds.** All Helm charts are pinned in `nix/constants.nix`
  with an SRI hash and templated at Nix build time. Container images are
  referenced by digest where possible. The whole VM image is a Nix
  derivation; given the same flake inputs, the same bits come out.
- **Rendered-manifest pattern preserved.** No in-cluster Helm operator and
  no ArgoCD Helm rendering. All YAML lives in `./rendered/` and is
  committed to git so the manifest set is an auditable artifact of every
  commit.
- **Minimal repo surface.** The source repo `nix-k8s-examples` ships ~14
  applications (Matrix, TiDB, ClickHouse, FoundationDB, CNPG, Forgejo,
  PowerDNS, Anubis, nginx demo, Zot registry, observability, hubble-otel,
  cert-manager, ArgoCD, Cilium). This repo keeps only what's needed to
  demonstrate Ceph: Cilium, ArgoCD, cert-manager, base manifests, OpenEBS,
  Rook operator, Rook cluster, ceph-demo.
- **Same build/run UX as the source repo.** `nix run .#k8s-cluster-rebuild`
  is still the one command to bring up a fresh cluster from cold.

## Repository layout

```
ceph-on-k8s/
├── flake.nix                          # apps, packages, devShell — trimmed from source
├── flake.lock                          # regenerated for the trimmed input set
├── README.md
├── LICENSE
├── .gitignore                          # adds *-ceph.img
├── docs/
│   ├── ceph-design.md
│   └── nix-design.md
├── certs/                              # build-time PKI output (gitignored)
├── secrets/                            # offline-generated secrets (gitignored)
├── rendered/                           # TRACKED — the audit trail
│   ├── base/                           # namespaces, RBAC, CoreDNS
│   ├── cilium/                         # CNI + L2 announce + LB IP pool
│   ├── argocd/
│   ├── cert-manager/                   # operator + ClusterIssuer
│   ├── openebs-device/                 # NDM + controller + StorageClass
│   ├── rook-operator/
│   ├── rook-cluster/                   # CephCluster + pools + RGW + CephFS + Ingress
│   └── ceph-demo/                      # one PVC per StorageClass + busybox proof pod
└── nix/
    ├── constants.nix                  # all chart pins, IPs, ports, sizes
    ├── nodes.nix                      # node registry: cp0, cp1, cp2, w3
    ├── microvm.nix                    # parametric VM generator
    ├── k8s-module.nix                 # vanilla kubernetes systemd services
    ├── network-setup.nix              # bridge + TAPs + haproxy on the host
    ├── certs.nix                      # build-time PKI (step-cli + openssl)
    ├── cert-inject.nix                # legacy serial-console cert transfer
    ├── secrets.nix                    # K8s Secret manifests from offline-generated material
    ├── secrets-gen.nix                # random material generator (offline)
    ├── shell.nix                      # devShell: kubectl, helm, cilium-cli, argocd, ceph
    ├── render-script.nix              # k8s-render-manifests app
    ├── microvm-scripts.nix            # start/stop/wipe/ssh apps
    ├── monitoring-module.nix          # Prometheus + Grafana on cp0
    ├── gitops-bootstrap-module.nix    # day-1 GitOps bootstrap (cp0 only)
    ├── chaos-scripts.nix              # OSD-failover chaos test
    ├── lifecycle/                     # integration test framework
    │   ├── default.nix
    │   ├── lib.nix
    │   ├── constants.nix
    │   ├── k8s-checks.nix             # adds `ceph -s` HEALTH_OK gate
    │   └── scripts/                   # *.exp expect scripts
    └── gitops/
        ├── default.nix                # aggregates env modules → k8s-manifests derivation
        ├── helm-chart.nix             # renderChart helper (unchanged from source)
        └── env/
            ├── base.nix               # namespaces, RBAC, CoreDNS
            ├── cilium.nix             # CNI + L2 announce + LB pool (range widened)
            ├── argocd.nix
            ├── cert-manager.nix       # + cluster-ca ClusterIssuer
            ├── openebs-device.nix     # NEW
            ├── rook-operator.nix      # NEW
            ├── rook-cluster.nix       # NEW
            └── ceph-demo.nix          # NEW
```

Compared to the source repo, the following are **removed**:

- `nix/gitops/env/{clickhouse,tidb,foundationdb,postgres,matrix,nginx,observability,pdns,forgejo,registry}.nix`
- `nix/gitops/matrix/` (subdirectory)
- `nix/{anubis,matrix,observability,registry}-scripts.nix`
- `nix/pdns-test.nix`, `nix/pdns-failover-test.nix`
- `nix/images/` (hubble-otel)

Removing these is what gives the rendered manifest tree its tight shape:
ArgoCD only watches the storage- and CNI-related applications, no other
controllers compete for CRD ownership, and `nix run .#k8s-render-manifests`
finishes in seconds instead of minutes.

## The rendered-manifest pattern

This is the architectural backbone of the source repo and is preserved
verbatim. Every component flows through these seven steps:

### 1. Chart pin in `nix/constants.nix`

Each Helm chart appears in the `helmCharts` attrset as a
`{ version; url; hash; }` triple. The hash is an SRI hash computed once
via `nix-prefetch-url` and stored alongside the URL; this makes the chart
download both reproducible and offline-safe (the tarball is cached in the
Nix store).

```nix
helmCharts = {
  cilium               = { version = "1.19.3"; url = "…"; hash = "sha256-…"; };
  argocd               = { version = "9.5.11"; url = "…"; hash = "sha256-…"; };
  certManager          = { version = "…";       url = "…"; hash = "sha256-…"; };
  openebsDeviceLocalpv = { version = "…";       url = "…"; hash = "sha256-…"; };  # NEW
  rookCephOperator     = { version = "v1.19.6"; url = "…"; hash = "sha256-…"; };  # NEW
  rookCephCluster      = { version = "v1.19.6"; url = "…"; hash = "sha256-…"; };  # NEW
};
```

### 2. Values as a multi-line Nix string in the env module

Each `nix/gitops/env/<component>.nix` defines its Helm values as a single
multi-line Nix string. This keeps values colocated with the manifest
generation code and lets it interpolate Nix values (constants, paths,
secrets). Example for the Rook cluster:

```nix
clusterValuesYaml = ''
  cephClusterSpec:
    mon: { count: 3, allowMultiplePerNode: false }
    storage:
      useAllNodes: false
      storageClassDeviceSets:
      - name: ceph-osd-set
        count: 4
        volumeClaimTemplates:
        - metadata: { name: data }
          spec:
            storageClassName: ${constants.openebs.storageClassName}
            accessModes: [ReadWriteOnce]
            volumeMode: Block
            resources: { requests: { storage: ${toString constants.ceph.osd.sizeGiPerOsd}Gi } }
  …
'';
```

### 3. Build-time `helm template`

The helper `helm.renderChart` (`nix/gitops/helm-chart.nix`) takes a chart
pin and a values string and returns a derivation whose `$out/install.yaml`
is the fully templated, CRDs-included multi-document YAML. The helper
unchanged from the source repo:

```nix
renderedCluster = helm.renderChart {
  name        = "rook-ceph-cluster";
  releaseName = "rook-ceph";
  namespace   = constants.ceph.namespace;
  chart       = constants.helmCharts.rookCephCluster;
  values      = clusterValuesYaml;
};
```

Templating happens **at Nix build time**, not at deploy time. The output
is deterministic given the chart hash, the chart version, and the values
string.

### 4. Aggregator collects manifests

`nix/gitops/default.nix` imports every env module, concatenates their
`manifests` lists, and emits a single derivation `k8s-manifests` whose
output is a directory tree of YAML files. Each manifest entry is one of:

```nix
{ name = "rook-cluster/install.yaml"; source  = "${renderedCluster}/install.yaml"; }  # file copy
{ name = "rook-cluster/application.yaml"; content = "…multi-line YAML…"; }            # inline string
```

The `source` form is required for files that came out of another Nix
derivation (like `helm template` output); the `content` form is used for
hand-written manifests like the ArgoCD `Application` CRs.

### 5. Render to `./rendered/`

`nix run .#k8s-render-manifests` invokes `nix/render-script.nix`, which:

- Builds the `k8s-manifests` derivation.
- Copies the result to `./rendered/` (deleting old files, preserving git
  metadata).
- Verifies idempotency: a second invocation must produce an identical
  tree.

The `./rendered/` directory is committed to git. This is the audit trail.
A reviewer can see exactly what YAML each commit ships without running
any Nix.

### 6. Bootstrap reads from the Nix store

On the first boot of `cp0`, the systemd unit `k8s-gitops-bootstrap`
(defined in `nix/gitops-bootstrap-module.nix`) needs to apply a small set
of foundational manifests **before** CNI is up and the cluster can pull
from a git remote. It reads them directly from `/nix/store` via the
`cfg.manifestsPath` option, which microvm.nix wires to the `k8s-manifests`
derivation.

This is why the bootstrap is **not** simply "ArgoCD bootstrap from git" —
ArgoCD needs CNI, CNI is in the manifest set, and you can't `git clone`
without CNI. So the bootstrap unit runs `kubectl apply -f` against the
local store path for the critical-path manifests:

1. Cilium (CNI)
2. base (namespaces, RBAC, CoreDNS)
3. cert-manager
4. **OpenEBS Local PV Device**
5. **Rook operator** (waits for CRDs)
6. **CephCluster CR** (waits for `status.phase == Ready`)
7. ArgoCD (server + CRDs)
8. Pre-generated Secrets
9. All `Application` CRs → ArgoCD takes over

After step 9, ArgoCD watches `./rendered/` in the cloned git repo and
reconciles drift.

### 7. ArgoCD reconciles from git

Each component's env module also emits a small `application.yaml` —
an ArgoCD `Application` CR — pointing at `rendered/<component>/`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rook-cluster
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/randomizedcoder/ceph-on-k8s.git
    targetRevision: main
    path: rendered/rook-cluster
    directory:
      recurse: false
      exclude: '{application.yaml,values.yaml}'
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true, CreateNamespace=true]
```

On any commit that changes `rendered/rook-cluster/install.yaml`, ArgoCD
applies the delta within ~3 minutes (the default polling interval).

## Storage stack in Nix terms

Each layer of the storage stack maps to a specific Nix file:

| Layer | Nix file | What it produces |
|---|---|---|
| Sparse host file `${hostname}-ceph.img` | `nix/microvm.nix` | A `volumes` entry with `autoCreate = true` |
| `virtio-blk` device in the guest with stable serial | `nix/microvm.nix` | Same `volumes` entry sets `serial = "ceph-osd-${hostname}"` |
| Raw block device in the guest at `/dev/disk/by-id/virtio-ceph-osd-*` | Linux kernel; nothing in Nix | (just appears) |
| Required kernel modules (rbd, ceph, nbd, dm_thin_pool) | `nix/k8s-module.nix` | `boot.kernelModules` list |
| `BlockDevice` CR claim on the raw disk | `nix/gitops/env/openebs-device.nix` | OpenEBS NDM Helm chart values |
| `openebs-device` StorageClass | `nix/gitops/env/openebs-device.nix` | Inline manifest |
| Rook operator + CSI plugins | `nix/gitops/env/rook-operator.nix` | rook-ceph chart, templated |
| CephCluster CR + pools + RGW + CephFS + LB Services + Ingress | `nix/gitops/env/rook-cluster.nix` | rook-ceph-cluster chart, templated, plus inline LB/Ingress |
| Demo PVCs and busybox proof pod | `nix/gitops/env/ceph-demo.nix` | Inline manifests |

## The second disk

The single most impactful change to `nix/microvm.nix` compared to the
source repo is the addition of a second `volumes` entry per VM:

```nix
volumes = [
  {
    # Existing data volume — unchanged from source repo
    image      = "${hostname}-data.img";
    mountPoint = "/var/lib";
    size       = 20480;          # 20 GiB
  }
  {
    # New raw OSD volume
    image      = "${hostname}-ceph.img";
    mountPoint = null;           # critical: skip the auto-mount path
    size       = 10240;          # 10 GiB (lab-only)
    autoCreate = true;
    fsType     = "ext4";         # filler — header gets wiped by OSD prepare
    serial     = "ceph-osd-${hostname}";
  }
];
```

The `mountPoint = null` is critical. The upstream `microvm.nixosModules.microvm`
mounts.nix only registers a filesystem when `mountPoint != null`, so this
volume appears in the guest as a raw `/dev/vdb` with no `fileSystems`
entry, no fstab line, and no `mkfs` run by the systemd-mount unit. NDM
sees an untouched block device, which is exactly what OpenEBS Local PV
Device needs.

The `serial` field is exposed by QEMU's `virtio-blk-pci` as
`/dev/disk/by-id/virtio-ceph-osd-<host>`. The CephCluster CR references
disks by this stable path rather than `/dev/vdb`, surviving any future
reordering of the volumes list.

## Build and boot flow

The full cold-boot sequence after `nix run .#k8s-cluster-rebuild`:

```
┌───────────────────────────────────────────────────────────────────┐
│ Nix build phase (host)                                            │
│  1. nix build .#k8s-pki        → /nix/store/<pki>                 │
│  2. nix build .#k8s-manifests  → /nix/store/<manifests>           │
│       (helm templates Cilium, ArgoCD, cert-manager, openebs,     │
│        rook-operator, rook-cluster; concatenates with base &     │
│        inline manifests; emits to result/)                       │
│  3. nix build .#k8s-microvm-<node> for each of cp0/cp1/cp2/w3   │
│       (bakes pki + manifests into each VM image)                  │
└───────────────────────────────────────────────────────────────────┘
                                │
┌───────────────────────────────────────────────────────────────────┐
│ Host network setup (sudo)                                         │
│  k8s-network-setup creates bridge k8sbr0, 4 TAPs, NAT,            │
│  starts haproxy on 10.33.33.1:6443                                │
└───────────────────────────────────────────────────────────────────┘
                                │
┌───────────────────────────────────────────────────────────────────┐
│ VM start (4 microvms via microvm.declaredRunner)                  │
│  Each VM:                                                          │
│   - 9p shares /nix/store read-only                                │
│   - Creates ${hostname}-data.img (20 GiB) + ${hostname}-ceph.img  │
│     (10 GiB) if missing                                            │
│   - boots NixOS into systemd                                       │
│   - systemd-networkd configures dual-stack static IP              │
│   - activation script copies PKI from /nix/store → /var/lib/      │
│     kubernetes/pki                                                 │
│   - kubelet + containerd start                                     │
│   - etcd starts on cp0/cp1/cp2; apiserver/controller/scheduler    │
│     start as static pods                                           │
└───────────────────────────────────────────────────────────────────┘
                                │
┌───────────────────────────────────────────────────────────────────┐
│ Day-1 bootstrap (cp0 only, systemd oneshot)                       │
│  See "Bootstrap reads from the Nix store" above                   │
│  Total runtime: ~10 minutes (OSD prepare dominates)               │
└───────────────────────────────────────────────────────────────────┘
                                │
┌───────────────────────────────────────────────────────────────────┐
│ Day-2+ reconciliation                                              │
│  ArgoCD watches the cloned git repo's rendered/ tree              │
│  Any commit that changes a manifest triggers a sync within ~3 min │
└───────────────────────────────────────────────────────────────────┘
```

## Workflow for changes

The user-facing edit cycle for any non-trivial change is:

```bash
$EDITOR nix/constants.nix                    # bump chart pin, sizes, IPs
$EDITOR nix/gitops/env/<component>.nix       # adjust values or CRs
nix run .#k8s-render-manifests               # regenerates rendered/
git diff rendered/                            # review the YAML delta
git add nix/ rendered/ && git commit
git push                                      # ArgoCD will pull within ~3 min
```

For the bootstrap-critical components (Cilium, base, cert-manager,
OpenEBS, Rook, CephCluster), the change won't take effect on cold boot
until `k8s-cluster-rebuild` runs — those manifests are baked into the VM
image via the Nix store, not pulled from git at boot time. ArgoCD does
still reconcile them at day 2+, so a rolling change works on a live
cluster.

## What's preserved verbatim from the source repo

- The microvm runtime layer (`microvm.nixosModules.microvm`, 9p store
  share, virtio console plumbing).
- The build-time PKI (`nix/certs.nix`) — 3 CAs (cluster, etcd,
  front-proxy), per-node bundles, baked into VM images.
- The host network setup (bridge, 4 TAPs, haproxy on `10.33.33.1:6443`,
  nftables masquerade).
- Vanilla upstream Kubernetes binaries via `nix/k8s-module.nix` (no
  kubeadm, no k3s; etcd + apiserver + controller-manager + scheduler +
  kubelet + containerd, each a systemd service).
- The bootstrap idempotency marker
  (`/var/lib/k8s-bootstrap/done`).
- The lifecycle test framework (`nix/lifecycle/`), extended with a
  `ceph -s` HEALTH_OK assertion.
- The devShell (`nix/shell.nix`), extended with the `ceph` CLI and a
  `mc` (MinIO client) for S3 smoke tests.

## What's new in this repo

- A second `volumes` entry per VM (raw 10 GiB Ceph OSD disk).
- Four kernel modules added to `boot.kernelModules`.
- Three new chart pins in `constants.nix.helmCharts`.
- A new top-level `ceph` attrset and `openebs` attrset in
  `constants.nix`.
- Four new env modules: `openebs-device.nix`, `rook-operator.nix`,
  `rook-cluster.nix`, `ceph-demo.nix`.
- Two new bootstrap steps in `gitops-bootstrap-module.nix` (OpenEBS,
  Rook operator) plus the CephCluster wait.
- A `ClusterIssuer/cluster-ca` added to `cert-manager.nix` so the
  dashboard and S3 endpoint can be issued certs from the build-time CA.
- A widened Cilium LB IP pool covering `10.33.33.50–10.33.33.54`.
- A rewritten `chaos-scripts.nix` targeting OSD failover instead of the
  source repo's database failover.
