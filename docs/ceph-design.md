# Ceph storage cluster design

This document describes the Ceph storage cluster that runs on top of a 4-node
NixOS MicroVM Kubernetes cluster. It explains the daemon topology, the storage
stack from raw disk up through the StorageClasses exposed to applications, the
replication and failure-domain choices, and the trade-offs that follow from the
"lab-only" sizing.

It does **not** describe how the Nix code is organized or how the cluster is
built; see [`nix-design.md`](./nix-design.md) for that.

## Goals and constraints

- Demonstrate a **working** Ceph cluster providing block, shared-filesystem,
  and S3-object storage on top of a small NixOS MicroVM Kubernetes cluster.
- Use **Rook-Ceph** as the operator, deployed via the rendered-manifest
  pattern inherited from the source repo `nix-k8s-examples`. No in-cluster
  Helm templating; all manifests are produced at Nix build time and committed
  to git.
- Use **OpenEBS Local PV Device** as the underlying provisioner so each OSD
  is backed by a raw-block PersistentVolume carved from a dedicated host disk
  per node. This gives Rook a CSI StorageClass it can consume via PVC-based
  OSDs (`storageClassDeviceSets`), exactly the cloud-native pattern.
- Survive single-node failure on the storage layer (replication factor 3
  across `host` failure domain).
- Surface the Ceph MGR dashboard and the RGW S3 endpoint on stable VIPs
  reachable from the host, with TLS terminated at the Cilium ingress.
- Keep the host footprint small enough to run on a laptop: **10 GiB per
  node** of dedicated Ceph storage (4 × 10 GiB = 40 GiB raw on the host).
  This is **below** the production minimum and is documented as a lab-only
  choice.

## Storage stack

The layered architecture is:

```
  Demo workloads      ─ Block PVC, RWX FS PVC, S3 ObjectBucketClaim
        │
  Ceph services       ─ RBD pool · CephFS · RGW (S3) · MGR dashboard
        │
  Rook-Ceph cluster   ─ 3 MON · 2 MGR · 4 OSD (PVC-based) · 3 MDS · 2 RGW
        │
  Rook-Ceph operator  ─ CSI plugins (rbd + cephfs) on every node
        │
  OpenEBS Local-PV-Device         ─ StorageClass `openebs-device`
   (NDM tags + raw-block PVs)
        │
  Guest OS            ─ /dev/disk/by-id/virtio-ceph-osd-<host>
                         (10 GiB, unformatted, raw)
        │
  MicroVM             ─ second virtio-blk volume: ${hostname}-ceph.img
        │
  Host                ─ sparse 10 GiB file per node in the repo root
```

Each layer is owned by exactly one piece of software:

| Layer | Owner |
|---|---|
| Sparse file on host | nix microvm runner (`autoCreate = true`) |
| `virtio-blk` device | QEMU launched by microvm.nix |
| Raw block in guest | Linux kernel (driver `virtio_blk`) |
| `BlockDevice` CR (claim of the raw disk) | OpenEBS NDM |
| `openebs-device` StorageClass | OpenEBS Local PV Device CSI |
| `ceph-osd-set` PVCs (one per node) | Rook operator |
| OSD daemons (Bluestore on raw block) | Rook cluster controller |
| RBD pool / CephFS / RGW | Rook cluster controller |
| `ceph-block` / `ceph-filesystem` / `ceph-bucket` StorageClasses | Rook |
| Application PVCs / OBCs | Workloads |

This strict layering means the failure of any one layer has a known blast
radius and a known repair procedure. For example, replacing a node's disk
means: stop the VM, delete `<host>-ceph.img`, restart the VM — NDM will
re-discover, OpenEBS will provision a fresh PV, Rook will rebuild the OSD,
Ceph will recover the missing replicas from the surviving 3 OSDs.

## Daemon topology

The CephCluster CR pins each daemon class to a node selector and an
anti-affinity rule. The 4-node lab cluster runs:

| Daemon | Count | Placement | Anti-affinity | Reason |
|---|---|---|---|---|
| MON | 3 | nodeAffinity `node-role.kubernetes.io/control-plane` | host | 3-way quorum survives one CP loss |
| MGR | 2 | spread across CPs | host | active/standby HA |
| OSD | 4 | one PVC per node | host (topology spread) | one OSD per physical disk |
| MDS | 3 | spread; 1 active + 2 standby | host | CephFS HA |
| RGW | 2 | spread | host | S3 HA |

Plus the supporting controllers and CSI:

- 1 × `rook-ceph-operator` Deployment
- 2 × `csi-rbdplugin-provisioner` Deployment, 2 × `csi-cephfsplugin-provisioner` Deployment
- 4 × `csi-rbdplugin` DaemonSet pods (one per node), 4 × `csi-cephfsplugin` DaemonSet pods
- 1 × `rook-ceph-tools` Deployment for `ceph` CLI debugging

Total: ~26 pods, ~6 GiB aggregate RAM. The source repo's CP nodes are 8 GiB /
4 vCPU and the worker is 6 GiB / 2 vCPU; this is tight and a memory bump to
10 GiB CP / 8 GiB worker is required before the CephCluster CR is applied.

### Why MONs prefer control planes

MON nodes hold the cluster map and the authoritative state of the storage
cluster. Putting them on the control-plane nodes ties their lifecycle to the
already-HA control-plane tier: when cp0/cp1/cp2 are up and healthy, MON
quorum is up and healthy. The worker `w3` carries an OSD but not a MON,
mirroring the asymmetric topology of the source repo (3 CP + 1 worker) and
keeping the worker free for application workloads.

A `tolerations` block for `node-role.kubernetes.io/control-plane:NoSchedule`
is added to every Rook daemon even though the source repo does not currently
taint CPs — this is a no-op today and prophylactic against any future taint
change.

### Why OSDs are PVC-based, not direct-device

Rook supports two OSD modes:

1. **Direct device discovery**: `storage.nodes[].devices=[{name: vdb}]` in
   the CephCluster CR. The OSD pod runs with `hostPath` access to the raw
   device, `ceph-volume` formats it, the OSD is bound to that node.
2. **PVC-based** (`storageClassDeviceSets`): the OSD requests a
   `volumeMode: Block` PVC from a StorageClass. The CSI driver attaches a
   raw block PV to the OSD pod, `ceph-volume` formats it. The OSD is
   bound to the PV, not the node.

This repo uses mode 2 (PVC-based on top of OpenEBS) for three reasons:

- It matches the user's intent ("OpenEBS managed block stores").
- It cleanly decouples the OSD identity from the host's device naming. The
  OSD doesn't care whether `/dev/vdb` is the right disk; it asks the CSI
  driver for a block PV, and OpenEBS NDM's tag filter ensures only the
  intended disk (`serial: ceph-osd-<host>`, tagged `ceph-osd`) can satisfy
  the claim.
- It is the canonical "cloud-native" Rook pattern. The same code paths run
  in production on AWS gp3, GKE pd-ssd, etc.

The trade-off is one extra component (OpenEBS) in the dependency chain. The
bootstrap order accounts for that.

## Pools and StorageClasses

Three top-level Ceph services, each exposing one StorageClass to consumers:

| Service | Object | Replication | StorageClass | Access mode |
|---|---|---|---|---|
| Block storage | `CephBlockPool/replicapool` | size 3, failureDomain `host` | `ceph-block` (default) | RWO |
| Shared filesystem | `CephFilesystem/ceph-filesystem` (metadata + 1 data pool) | size 3 each | `ceph-filesystem` | RWX |
| Object storage | `CephObjectStore/ceph-objectstore` (metadata + data pool) | size 3 each | `ceph-bucket` (ObjectBucketClaim) | bucket |

All three pools use **replication factor 3** with `failureDomain: host`. With
4 OSDs spread across 4 hosts, Ceph can:

- Tolerate the failure of any one host (3 replicas survive on the remaining
  3 hosts).
- **Not** rebalance the missing replica onto another host while the failed
  host is down, because there's only one OSD per host — Ceph has nowhere to
  put the new copy of the data. The cluster goes to HEALTH_WARN until the
  failed host returns.

This is the price of one-OSD-per-host on a 4-host cluster, not a defect.
Scaling up means either (a) adding a second OSD per host (a one-line change
in `constants.nix`), or (b) adding a 5th node so Ceph can rebalance during a
single-host outage.

### Storage math

```
  Raw capacity     : 4 nodes × 10 GiB = 40 GiB
  Useable (3 reps) : 40 / 3 ≈ 13 GiB
  Practical        : ≈ 10 GiB after Ceph's ~20% near-full reserve
                     and Bluestore's ~5 GiB-per-OSD metadata overhead
```

10 GiB is **below** Bluestore's recommended minimum. It is sufficient to
prove the configuration end-to-end with the small demo workload (1 GiB
block PVC + 1 GiB FS PVC + a small S3 bucket) but **not** for any real
workload. Scaling up is a one-line change in `nix/constants.nix`:

```nix
ceph.osd.diskSizeGi = 10;   # bump this for real use
```

The change propagates through `nix/microvm.nix` (image file size) and the
`storageClassDeviceSets.volumeClaimTemplates` block in
`nix/gitops/env/rook-cluster.nix` (PVC request size). Bumping the host
image and the PVC request to the same value keeps the layers consistent.

## Network exposure

Two services need to be reachable from outside the cluster: the Ceph MGR
dashboard (a web UI on port 8443 inside the cluster) and the RGW S3
endpoint (HTTP on port 80 inside the cluster). Both are exposed via
**Cilium L2-announced LoadBalancer VIPs**, the same mechanism the source
repo uses for the Zot registry.

| Service | Host | VIP | Mechanism | TLS |
|---|---|---|---|---|
| Ceph dashboard | `ceph.lab.local` | `10.33.33.53` | Cilium Ingress | Terminated at ingress, cert from cluster CA via cert-manager |
| RGW S3 | `s3.lab.local` | `10.33.33.54` | LoadBalancer Service | Terminated at ingress, cert from cluster CA via cert-manager |

The Cilium IP pool is widened from a single `10.33.33.50` (the existing
ingress VIP) to a range `10.33.33.50–10.33.33.54` covering both new VIPs.
A second `CiliumL2AnnouncementPolicy` selects the ceph services by label
so the existing ingress policy is not touched.

### Dashboard TLS approach

The Rook chart can self-sign the dashboard with `dashboard.ssl: true`, but
the result is a browser warning. Instead this design sets
`dashboard.ssl: false` and terminates TLS at the Cilium Ingress with a
cert issued by cert-manager from a `ClusterIssuer` backed by the
build-time cluster CA. The dev-machine `/etc/hosts` already trusts the
cluster CA (it's copied to the host during PKI setup), so the dashboard
loads cleanly.

### S3 addressing style

Phase 1 supports **path-style** S3 only (`https://s3.lab.local/<bucket>/<key>`),
because the dedicated VIP serves one virtual host. Phase 2 would add a
wildcard cert and `*.s3.lab.local` DNS for virtual-host-style addressing;
that's deferred since most lab clients (mc, awscli with `--addressing-style
path`) support path-style fine.

## Bootstrap and reconciliation

The CephCluster does not come up by ArgoCD — it comes up by the
**gitops-bootstrap** systemd unit on `cp0` during first boot, in this order:

1. Wait for apiserver
2. Apply Cilium (CNI); wait for the DaemonSet
3. Apply base manifests (namespaces, RBAC, CoreDNS); wait for CoreDNS
4. Apply cert-manager + ClusterIssuer; wait for the webhook
5. **Apply OpenEBS Local PV Device**; wait for NDM and the controller
6. **Apply Rook operator**; wait for the operator Deployment and the CRDs
7. **Apply the CephCluster CR + pools + RGW + CephFS**; wait for
   `cephcluster.status.phase == Ready` (up to 15 minutes — OSD prepare
   takes ~3 minutes per OSD on first boot)
8. Apply ArgoCD; wait for the server Deployment
9. Apply pre-generated Secrets
10. Apply all `Application` CRs — ArgoCD takes over from here

After step 10, ArgoCD reconciles `rendered/openebs-device/`,
`rendered/rook-operator/`, `rendered/rook-cluster/`, and
`rendered/ceph-demo/` from the cloned git repo. On any subsequent
configuration change (e.g. bumping the OSD disk size or adding a pool),
the workflow is:

```bash
$EDITOR nix/constants.nix nix/gitops/env/rook-cluster.nix
nix run .#k8s-render-manifests   # regenerates rendered/
git add nix/ rendered/ && git commit && git push
# ArgoCD detects the change within ~3 min and applies it.
```

The bootstrap unit is idempotent — once `/var/lib/k8s-bootstrap/done`
exists on `cp0`, it does not re-run on reboot.

## Failure modes and recovery

| Failure | Symptom | Recovery |
|---|---|---|
| One node down | 1 OSD + maybe 1 MON down; HEALTH_WARN | Restart the node; OSD/MON re-join; cluster returns to HEALTH_OK in ~1 min |
| Two nodes down | MON quorum lost (2 of 3 MONs gone); cluster halts I/O | Recover at least one node; manual MON quorum repair if needed |
| One node's `*-ceph.img` corrupted | One OSD permanently down; HEALTH_WARN | Delete the image file on the host; restart VM; NDM re-discovers; new PV; Rook prepares a new OSD; data backfilled from surviving replicas |
| OpenEBS controller down | New PVCs from `openebs-device` fail; existing PVCs unaffected | ArgoCD/Rook self-heal restarts the controller |
| Rook operator down | No new daemons created; existing daemons unaffected | ArgoCD self-heal |
| Apiserver / etcd quorum failure | Whole cluster halts | Same as the source repo — haproxy on the host bridge load-balances apiserver across the 3 CPs; etcd needs 2/3 |

The `nix/chaos-scripts.nix` script in this repo is a rewrite of the source
repo's database-failover chaos test: it kills a node, waits for
`ceph -s` to return to HEALTH_OK, and records the recovery time.

## Verification

The full end-to-end verification — used both by humans and by the
lifecycle test framework — is:

```bash
# Cluster up
nix run .#k8s-cluster-rebuild

# Storage tier health
nix run .#k8s-vm-ssh -- cp0 -- kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph -s
# expect: HEALTH_OK · 3 mons · 2 mgrs · 4 osd up,in · 3 mds · 2 rgw

# StorageClasses present
nix run .#k8s-vm-ssh -- cp0 -- kubectl get sc
# expect: ceph-block (default) · ceph-filesystem · ceph-bucket · openebs-device

# Demo workload uses all three
nix run .#k8s-vm-ssh -- cp0 -- kubectl -n ceph-demo get pvc,obc,pod
# expect: PVC ceph-block-test Bound · PVC ceph-fs-test Bound · OBC ceph-s3-test Bound · pod Running

nix run .#k8s-vm-ssh -- cp0 -- \
  kubectl -n ceph-demo exec deploy/ceph-smoke -- \
  sh -c 'dd if=/dev/zero of=/data/block/x bs=1M count=10 && \
         touch /data/fs/x && \
         env | grep BUCKET_'

# Dashboard reachable from host
curl -k --resolve ceph.lab.local:443:10.33.33.53 https://ceph.lab.local/
```

A passing run of all three commands above is the definition of "ceph-on-k8s
works".
