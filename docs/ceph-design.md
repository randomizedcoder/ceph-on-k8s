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
- Use **direct device discovery** so Rook's OSD pods reference raw
  `/dev/disk/by-id/virtio-ceph-osd-<host>` paths directly via the
  CephCluster CR's `storage.nodes[].devices` list. No CSI layer below
  Rook. We initially planned to use OpenEBS Local PV Device for
  PVC-backed OSDs, but the project is archived and its v0.9.0 agent
  requires a non-trivial meta-partition scheme. Direct device discovery
  is the canonical Rook fallback and works without an intermediate CSI
  layer — a small `ceph-disk-init` oneshot in `nix/k8s-module.nix` wipes
  any filesystem header so `ceph-volume` can take the disk fresh.
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
  Rook-Ceph cluster   ─ 3 MON · 2 MGR · 4 OSD (direct device) · 2 MDS · 1 RGW
        │
  Rook-Ceph operator  ─ CSI plugins (rbd + cephfs) on every node
        │
  Guest OS            ─ /dev/disk/by-id/virtio-ceph-osd-<host>
                         (10 GiB, unformatted, raw)
        │
  MicroVM             ─ second virtio-blk volume: ${hostname}-ceph.img
                         with serial=ceph-osd-<host>
        │
  Host                ─ sparse 10 GiB file per node in the repo root
```

Each layer is owned by exactly one piece of software:

| Layer | Owner |
|---|---|
| Sparse file on host | nix microvm runner (`autoCreate = true`) |
| `virtio-blk` device | QEMU launched by microvm.nix |
| Raw block in guest | Linux kernel (driver `virtio_blk`) |
| `/dev/disk/by-id/virtio-ceph-osd-<host>` symlink | systemd-udevd (from `serial=`) |
| OSD daemon (Bluestore on raw block) | Rook cluster controller via `ceph-volume raw prepare --bluestore` |
| RBD pool / CephFS / RGW | Rook cluster controller |
| `ceph-block` / `ceph-filesystem` / `ceph-bucket` StorageClasses | Rook |
| Application PVCs / OBCs | Workloads |

This strict layering means the failure of any one layer has a known blast
radius and a known repair procedure. For example, replacing a node's disk
means: stop the VM, delete `<host>-ceph.img`, restart the VM — the disk
comes back as a fresh raw device, the `ceph-disk-init` oneshot zeros any
filesystem header, Rook's OSD prepare job runs `ceph-volume raw prepare`,
the OSD rejoins, and Ceph recovers the missing replicas from the
surviving 3 OSDs.

## Daemon topology

The CephCluster CR pins each daemon class to a node selector and an
anti-affinity rule. The 4-node lab cluster runs:

| Daemon | Count | Placement | Anti-affinity | Reason |
|---|---|---|---|---|
| MON | 3 | nodeAffinity `node-role.kubernetes.io/control-plane` | host | 3-way quorum survives one CP loss |
| MGR | 2 | spread across CPs | host | active/standby HA |
| OSD | 4 | one raw disk per node | host (topology spread) | one OSD per physical disk |
| MDS | 2 | spread; 1 active + 1 hot standby | host | CephFS HA (`activeStandby: true`) |
| RGW | 1 | one instance | host | S3 endpoint |

Plus the supporting controllers and CSI:

- 1 × `rook-ceph-operator` Deployment
- 2 × `csi-rbdplugin-provisioner` Deployment, 2 × `csi-cephfsplugin-provisioner` Deployment
- 4 × `csi-rbdplugin` DaemonSet pods (one per node), 4 × `csi-cephfsplugin` DaemonSet pods
- 1 × `rook-ceph-tools` Deployment for `ceph` CLI debugging

Total: ~26 pods, ~6 GiB aggregate RAM. CP nodes are sized **10 GiB / 4
vCPU** and the worker **8 GiB / 2 vCPU** (`vm.controlPlane` /
`vm.worker` in `nix/constants.nix`). That sizing is the minimum needed
to fit Rook's footprint plus the underlying K8s control plane; lower
values cause the OSD prepare jobs to OOM and Rook never reaches
`HEALTH_OK`.

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

### Why OSDs are direct-device, not PVC-based

Rook supports two OSD modes:

1. **Direct device discovery**: `storage.nodes[].devices=[{name: …}]` in
   the CephCluster CR. The OSD pod runs with `hostPath` access to the
   raw device, `ceph-volume` formats it, the OSD is bound to that node.
2. **PVC-based** (`storageClassDeviceSets`): the OSD requests a
   `volumeMode: Block` PVC from a StorageClass. The CSI driver attaches
   a raw block PV to the OSD pod, `ceph-volume` formats it. The OSD is
   bound to the PV, not the node.

This repo uses mode 1. We originally aimed for mode 2 with OpenEBS Local
PV Device as the underlying CSI provisioner, but OpenEBS Local PV Device
is archived and its v0.9.0 agent requires a non-trivial meta-partition
scheme that's poorly documented. Direct device discovery is the
canonical Rook fallback and has zero extra components in the dependency
chain.

The trade-off: the OSD's identity is tied to the host's device naming.
We mitigate that by giving the second virtio-blk volume a stable
`serial=ceph-osd-<hostname>`, which makes `systemd-udevd` create
`/dev/disk/by-id/virtio-ceph-osd-<hostname>` — the CephCluster CR
references that by-id path, not `/dev/vdb`, so PCI re-numbering across
boots is irrelevant.

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

### Per-workload pools

`replicapool` / `ceph-block` is the default block StorageClass for
generic workloads. Upcoming stateful apps — Redpanda and ClickHouse
are the immediate targets — each get their **own** `CephBlockPool` +
matching `StorageClass`, so quota, CRUSH rule, and class identity are
per-workload. Source of truth is `constants.ceph.workloadPools` in
`nix/constants.nix`:

```nix
ceph.workloadPools = {
  redpanda   = { poolName = "redpanda-block";   storageClassName = "ceph-block-redpanda";   fstype = "xfs";  };
  clickhouse = { poolName = "clickhouse-block"; storageClassName = "ceph-block-clickhouse"; fstype = "ext4"; };
};
```

Adding a workload = one new attrset member. The `renderBlockPool` helper
in `nix/gitops/env/rook-cluster.nix` fans the entries out into the
`cephBlockPools:` list with the same CSI parameter block as
`replicapool`.

All pools currently share the same 4 OSDs — logical isolation
(per-pool quota, CRUSH rule, class) only, no physical isolation. The
production target (NVMe + RoCEv2 + RDMA) will eventually want either
device-class tagging (Phase 2 — add a second OSD disk per node tagged
e.g. `fast`, pin the hot pool to that class via `deviceClass:`) or a
separate storage backend like OpenEBS Mayastor for the hot path. Both
are deferred; the per-workload-pool pattern is the foundation either
extension builds on.

## Network exposure

Two services need to be reachable from outside the cluster: the Ceph MGR
dashboard (a web UI) and the RGW S3 endpoint. Both surface through the
**shared `cilium-ingress` LoadBalancer Service** on VIP `10.33.33.50`
— the same Service used by the existing ingress controller. The Cilium
LB IP pool covers `10.33.33.50–.54` so dedicated VIPs can be carved off
later without renumbering.

| Service | Host | Backend | TLS |
|---|---|---|---|
| Ceph dashboard | `ceph.lab.local` | `rook-ceph-mgr-dashboard:7000` | Termination at Cilium Ingress, cert issued by cert-manager from the `selfsigned-lab` ClusterIssuer |
| RGW S3 endpoint | `s3.lab.local` | `rook-ceph-rgw-ceph-objectstore:80` | Plain HTTP (path-style addressing only) |

Dev-box `/etc/hosts` entry:

```
10.33.33.50 ceph.lab.local s3.lab.local
```

### Dashboard TLS approach

The Rook chart can self-sign the dashboard with `dashboard.ssl: true`,
but the result is an opaque per-pod cert that browsers warn on every
visit. Instead the cluster sets `dashboard.ssl: false` and terminates
TLS at the Cilium Ingress using a cert that cert-manager issues from
the `selfsigned-lab` ClusterIssuer (an in-cluster CA defined in
`cert-manager.nix`). Browsers warn once; one-time accept of the
selfsigned-lab CA in the dev box's cert store removes the warning.

For production, swap `selfsigned-lab` for a `cluster-ca` ClusterIssuer
backed by the K8s Secret created from `/var/lib/kubernetes/pki/ca.{crt,key}`
— the dev box already trusts that CA. A small change to
`cert-manager.nix`; deferred from the lab scope.

### S3 addressing style

Phase 1 supports **path-style** S3 only
(`http://s3.lab.local/<bucket>/<key>`) because the shared cilium-ingress
serves one virtual host per Ingress rule. Phase 2 would add a wildcard
cert + `*.s3.lab.local` DNS for virtual-host-style addressing; deferred
since most lab clients (`mc`, `awscli --endpoint-url … --addressing-style
path`) handle path-style fine. RGW is exposed via plain HTTP for the
same reason — terminating TLS at the ingress would require a second cert
+ dedicated host, and S3 clients with `--no-verify-ssl` tolerate the
self-signed alternative if needed later.

## External CephFS client (`client0` microvm)

A NixOS microvm sitting on the same `k8sbr0` bridge as the K8s cluster
but **not** running Kubernetes. Demonstrates that CephFS can be mounted
from a real OS — no Rook CSI driver — exactly the way you'd mount it
from a bare-metal box.

### Topology

| Piece | Value |
|---|---|
| Host | `client0` / `k8s-client0`, IP `10.33.33.20`, TAP `k8stap4`, console block 25540–25549 |
| Disk | Single 4 GiB `${hostname}-data.img` mounted at `/var/lib`. No second disk. |
| Resources | 2 GiB RAM, 2 vCPU (vCPU=2 so the netdev `queues=` matches the multi-queue TAP). |
| Lifecycle | Independent of the cluster — `nix run .#k8s-client-start` / `…-stop` / `…-wipe`. NOT part of `k8s-start-all`. |

### MON exposure

Ceph daemons run on **`hostNetwork`**
(`cephClusterSpec.network.provider: host` in
`nix/gitops/env/rook-cluster.nix`). Each MON daemon binds to and
advertises its node's actual IP (10.33.33.10 / .11 / .12) on port 6789
(msgr-v1, the kernel default) and 3300 (msgr2).

**Why not LB VIPs or pinned MON pod IPs.** The kernel CephFS client
verifies that the address it connected to matches the address the MON
advertised in the MON map ("wrong peer at address" error if not). On
regular pod networking, Rook MONs advertise their **per-MON Service
ClusterIP** (10.96.x.x range, dynamic), not the pod IP — so neither
LoadBalancer VIPs nor pinning MON pod IPs via a `CiliumPodIPPool`
sidesteps the mismatch. `hostNetwork` is the only mode where the
advertised address equals an address an external client can reach.

eBPF impact is minor: BPF programs still attach to each node's primary
NIC, so inter-Ceph-daemon traffic across nodes is still processed by
Cilium. What's lost is per-pod IPAM / policy / identity for the ~5 Ceph
daemon types (mon/mgr/osd/mds/rgw) — none of which are perf-critical.
All non-Ceph workloads still use multi-pool IPAM + BGPControlPlane
(see [Network modes](#network-modes-bgp--multi-pool-ipam) below).

The client's `/etc/ceph/ceph.conf` is generated in `nix/secrets.nix`
from `constants.ceph.monHosts`:

```ini
[global]
mon_host = 10.33.33.10:6789,10.33.33.11:6789,10.33.33.12:6789
```

### CephX user (`client.external`)

Deterministic, build-time:

1. `nix run .#k8s-gen-secrets` produces a 30-byte CephX key blob
   (type=1, timestamp, length, 16-byte AES-128 key) into
   `secrets/cephfs-client.{secret,keyring}`. Plain `openssl rand 16`
   isn't enough — `ceph auth import` rejects it as "Malformed input".
2. A Kubernetes Job (`ceph-auth-import-external`) in `rook-ceph`
   mounts the same `rook-ceph-mon` admin Secret that
   `rook-ceph-tools` uses, builds a working `/etc/ceph/keyring`
   on-the-fly, then runs:

   ```
   ceph auth import -i /tmp/external.keyring  # caps inlined
   ceph auth caps client.external \
     mon "allow r fsname=ceph-filesystem" \
     mds "allow rw fsname=ceph-filesystem" \
     osd "allow rw tag cephfs data=ceph-filesystem"
   ```

   The Job is idempotent (same secret → no-op import; caps overwrite).

### Mount mechanics

`nix/microvm-client.nix` deliberately avoids `pkgs.ceph` /
`pkgs.ceph-client` because they currently pull in a Python tree that
clashes with nixpkgs' Sphinx version. Instead, the **kernel**'s CephFS
client does the work and the secret is inlined into the mount options:

```nix
fileSystems."/mnt/cephfs" = {
  device = "10.33.33.10:6789,10.33.33.11:6789,10.33.33.12:6789:/";
  fsType = "ceph";
  options = [
    "name=external"
    "secret=${cephClientSecret}"   # base64 key, inlined at build time
    "mds_namespace=ceph-filesystem"   # NOT `fs=`; newer kernels reject the old form
    "noatime" "_netdev"
    "x-systemd.requires=network-online.target"
    "x-systemd.after=network-online.target"
    "nofail"
  ];
};
```

`mount.ceph` is not required — the kernel parses these options
directly. `nofail` means the boot doesn't block forever if MONs are
unreachable; SSH still comes up so the operator can diagnose.

### bonnie++

`pkgs.bonnie` (bonnie++) is in `systemPackages` for quick disk-I/O
benchmarks against `/mnt/cephfs`. The total Ceph capacity is small
(~10 GiB usable on the lab cluster) and bonnie++'s defaults assume a
2× RAM dataset, so override the RAM hint when running with a smaller
file:

```bash
nix run .#k8s-vm-ssh -- --node=client0 -- \
  'bonnie++ -d /mnt/cephfs -s 512 -r 256 -n 0 -u root -q'
```

### Bidirectional verification

```bash
# from the client
nix run .#k8s-vm-ssh -- --node=client0 -- 'mount | grep cephfs'
# cephfs on /mnt/cephfs type ceph (rw,relatime,name=external,...)

nix run .#k8s-vm-ssh -- --node=client0 -- \
  'echo "from-client @ $(date)" > /mnt/cephfs/external.txt'

# read the same file from the in-cluster ceph-demo pod
nix run .#k8s-vm-ssh -- --node=cp0 -- \
  'kubectl -n ceph-demo exec deploy/ceph-smoke -- cat /data/fs/external.txt'

# and the reverse direction
nix run .#k8s-vm-ssh -- --node=cp0 -- \
  'kubectl -n ceph-demo exec deploy/ceph-smoke -- sh -c "echo from-pod > /data/fs/pod.txt"'
nix run .#k8s-vm-ssh -- --node=client0 -- 'cat /mnt/cephfs/pod.txt'
```

## Network modes: BGP + multi-pool IPAM

Cilium runs with **multi-pool IPAM** (`ipam.mode: multi-pool`) and two
auto-created `CiliumPodIPPool`s:

| Pool | CIDR | Per-pod mask | Used by |
|---|---|---|---|
| `default` | 10.244.0.0/18 | /24 (per-node slice) | every non-annotated pod |
| `ceph-mon-pool` | 10.244.99.0/29 | /32 (per-pod) | pods annotated with `ipam.cilium.io/ip-pool: ceph-mon-pool` |

`ceph-mon-pool` was provisioned for the experimental "pin MON pod IPs +
route to them externally" design. That design is **currently unused**
because Rook MONs advertise their per-MON Service ClusterIP (not the
pod IP) in the MON map, which defeated the address-match check
regardless of how MON pods were addressed. The pool is kept in place
for future experiments; Ceph itself runs on hostNetwork (see
[External CephFS client → MON exposure](#mon-exposure)).

In parallel, `bgpControlPlane.enabled: true` is set in the Cilium Helm
values and three CRDs are rendered under `rendered/cilium/`:

- `CiliumBGPClusterConfig/lab-bgp-cluster` — every Linux node opens a
  BGP session to the host peer (10.33.33.1)
- `CiliumBGPPeerConfig/lab-bgp-peer` — eBGP, 10s keepalive / 30s
  holdtime, IPv4 unicast, advertisement selector `advertise=bgp`
- `CiliumBGPAdvertisement/lab-bgp-advert` — advertises every
  `CiliumPodIPPool` slice the node has been allocated

The cluster side is fully configured. **The host-side BGP peer is
optional.** Two paths:

| Path | What it does | Survives host reboot? |
|---|---|---|
| Static route (default) | `k8s-network-setup` runs `ip route replace 10.244.0.0/16 via 10.33.33.10 dev k8sbr0`. cp0 is the gateway; Cilium handles the rest. | Re-run `sudo nix run .#k8s-network-setup` after reboot |
| FRR `bgpd` (optional) | Import `host-setup/frr-bgp.nix` into the host's `/etc/nixos/configuration.nix`, `nixos-rebuild switch`. FRR peers with each cluster node, computes the per-prefix best path. | Yes |

Both paths give the host (and any microvm on the bridge, including
client0) routable access to the pod CIDR. The Ceph external client
doesn't currently rely on either — MONs are on hostNetwork — but the
demo workload pods in `ceph-demo` get pod-CIDR addresses, and any
external traffic to those pod IPs goes through the static route or BGP.

## Bootstrap and reconciliation

The bootstrap-critical components come up via the
**k8s-gitops-bootstrap** systemd unit on `cp0` during first boot
(defined in `nix/gitops-bootstrap-module.nix`). The unit:

1. Waits for the apiserver to answer.
2. Applies the manifests baked into the VM image at
   `/var/lib/k8s-bootstrap/` — Cilium install, base namespaces / RBAC /
   CoreDNS, ArgoCD install, the ArgoCD `Application` CRs that point at
   `rendered/` in git.
3. Waits for the CephCluster CR to reach `status.phase == Ready` (up to
   15 minutes — OSD prepare takes ~3 minutes per OSD on first boot).

After that, **ArgoCD reconciles every other manifest from git**:
`rendered/rook-operator/`, `rendered/rook-cluster/`,
`rendered/ceph-demo/`, `rendered/ceph-external-client/`, etc. The Helm
charts inside those directories are pre-rendered at Nix build time, so
ArgoCD only does plain `kubectl apply --server-side`.

On any subsequent configuration change (e.g. bumping the OSD disk size
or adding a pool):

```bash
$EDITOR nix/constants.nix nix/gitops/env/rook-cluster.nix
nix run .#k8s-render-manifests   # regenerates rendered/
git add nix/ rendered/ && git commit && git push
# ArgoCD detects the change within ~3 min and applies it.
```

If the change is **bootstrap-critical** (anything Cilium, ArgoCD, or
base, plus the in-image CephCluster spec), a fresh
`nix run .#k8s-cluster-rebuild` is needed for it to take effect on the
next cold boot — the bootstrap unit reads from the Nix store, not git.

The bootstrap unit is idempotent — once
`/var/lib/k8s-bootstrap/done` exists on `cp0`, it does not re-run on
reboot.

## Failure modes and recovery

| Failure | Symptom | Recovery |
|---|---|---|
| One node down | 1 OSD + maybe 1 MON down; HEALTH_WARN | Restart the node; OSD/MON re-join; cluster returns to HEALTH_OK in ~1 min |
| Two nodes down | MON quorum lost (2 of 3 MONs gone); cluster halts I/O | Recover at least one node; manual MON quorum repair if needed |
| One node's `*-ceph.img` corrupted | One OSD permanently down; HEALTH_WARN | Delete the image file on the host; restart VM; `ceph-disk-init` wipes the fresh device; Rook prepares a new OSD; data backfilled from surviving replicas |
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
# expect: HEALTH_OK · 3 mons · 2 mgrs · 4 osd up,in · 3 mds · 1 rgw

# StorageClasses present
nix run .#k8s-vm-ssh -- cp0 -- kubectl get sc
# expect: ceph-block (default) · ceph-filesystem · ceph-bucket

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
