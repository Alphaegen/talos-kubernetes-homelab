# Single Control-Plane Recovery

This cluster has one Kubernetes control-plane and one etcd member: `rpi-cp-1`
at `192.168.20.101`. Loss of that node makes the Kubernetes API unavailable,
but worker-hosted workloads and Longhorn data can continue running.

All commands below use `talosctl` on `PATH` at the version pinned in
[`.tool-versions`](../.tool-versions) (for example via `asdf` or `mise` from the
repository root). Check it before any maintenance:

```bash
talosctl version --client --short
```

During a Talos upgrade or rollback, use the client matching the version you
are moving to, for example `asdf install talosctl <version>` and then
`ASDF_TALOSCTL_VERSION=<version> talosctl ...` (or the `mise` equivalent).

## Storage identity

- The Talos system disk is the Raspberry Pi SD card, `/dev/mmcblk0`.
- `STATE` and `EPHEMERAL` are `/dev/mmcblk0p5` and `/dev/mmcblk0p6`.
- `machine.install.disk` must remain `/dev/mmcblk0` for install and recovery.
- The control-plane NVMe, `/dev/nvme0n1`, must never be selected as Talos
  install or recovery media.
- `/dev/nvme0n1p1` currently has an XFS filesystem and the historical partition
  label `u-longhorn`. It is not mounted, `rpi-cp-1` is not a Longhorn node,
  and no active Longhorn replica is registered on it. Its contents have not
  been audited, so treat it as preserved residual storage: do not wipe,
  repartition, format, or use it during control-plane recovery.
- Active Longhorn disks and replicas are restricted to `rpi-w-1`, `rpi-w-2`,
  and `rpi-w-3`, using `/var/mnt/longhorn` on each worker NVMe.

Verify both the configured and discovered system disks before maintenance:

```bash
talosctl --context home-cluster -e 192.168.20.101 -n 192.168.20.101 get systemdisk
talosctl --context home-cluster -e 192.168.20.101 -n 192.168.20.101 \
  get machineconfig v1alpha1 -o json | jq -r .spec | yq '.machine.install'
```

Both disk values must identify `/dev/mmcblk0`. Stop if they differ.

## Protected recovery material

Talos machine configurations contain secrets and must never be committed.

An etcd snapshot is only usable together with the Talos secrets bundle,
`~/.talos/homelab/secrets.yaml`: a replacement control-plane must be generated
from the same cluster secrets (`./generate.sh` reads that file). Back the
bundle up separately on independent storage; never put it in Git or next to
the automated snapshots on the NAS. Protect it, the recovery bundle,
talosconfig, kubeconfig, and etcd snapshots as one recovery set, and keep a
second copy on independent storage before control-plane mutation.

A historical recovery bundle from the Talos 1.12 upgrade is stored outside the
repository at:

```text
~/talos-upgrade-backups/20260909T111941Z-control-plane-recovery/
```

It contains the live configuration captured before and after the install-disk
correction to `/dev/mmcblk0`, a Talos 1.12 configuration set generated from
the original secret bundle, and Raspberry Pi ARM64 SD images with matching
clients. It predates the versions pinned in `.tool-versions` and
`generate.sh`; for a current recovery, regenerate the configuration with
`./generate.sh` and use an SD image for the Talos version currently running.

## Automated etcd snapshots

The `etcd-backup` Argo CD Application
([`gitops/infra-custom/etcd-backup`](../gitops/infra-custom/etcd-backup))
runs the `etcd-snapshot` CronJob every night at 02:30 Europe/Amsterdam, after
the Longhorn `backup-all` job at 00:00.

- It authenticates with a Talos `ServiceAccount` in the `etcd-backup`
  namespace. Talos creates and rotates a talosconfig Secret limited to the
  `os:etcd:backup` role. This requires `machine.features.kubernetesTalosAPIAccess`
  from [`patches/controlplane.yaml`](../patches/controlplane.yaml) to be
  applied to `rpi-cp-1`; no Talos credentials are stored in Git.
- Snapshots land on the NAS share `nas.niekvlam.nl:/volume1/etcd-backups` as
  `etcd-<UTC timestamp>.snapshot`, each with a matching `.sha256` file.
- The newest 14 snapshots are kept; older ones and their checksums are pruned
  only after a new snapshot has been written and verified.
- A failed snapshot fails the Job (non-zero exit), which the default
  Kubernetes job alerts report through Alertmanager.

Prerequisites, in this order:

1. On the NAS, create the dedicated shared folder `etcd-backups`
   (`/volume1/etcd-backups`). It is separate from the Longhorn backup target
   and the media shares. Add an NFS rule: client `192.168.20.0/24`,
   read/write, squash "No mapping", NFSv4.1 enabled. Change the folder's
   owner to `12022:12022`, the UID/GID the CronJob runs as.
2. Run `./generate.sh`, then `./apply.sh rpi-cp-1`, to enable Talos API access
   for the `etcd-backup` namespace. This applies without a reboot. Afterwards
   `kubectl get crd serviceaccounts.talos.dev` and
   `kubectl -n default get service talos` must both exist.
3. Merge and let Argo CD sync. Apply the Talos patch before, or shortly after,
   merging: until the `talos.dev` CRD exists the sync fails and is retried
   for about an hour, after which it needs a manual sync. Talos then creates
   the `etcd-backup` Secret in the `etcd-backup` namespace.

Run it on demand and check the result:

```bash
JOB="etcd-snapshot-manual-$(date +%s)"
kubectl -n etcd-backup create job --from=cronjob/etcd-snapshot "$JOB"
kubectl -n etcd-backup wait --for=condition=complete --timeout=10m "job/$JOB"
kubectl -n etcd-backup logs "job/$JOB" -c snapshot
kubectl -n etcd-backup logs "job/$JOB" -c rotate
```

To fetch a snapshot, copy it together with its `.sha256` file from the NAS
share to the workstation and verify it as described in
[Test a snapshot](#test-a-snapshot). Nightly snapshots do not replace the
fresh manual snapshot required before control-plane maintenance.

## Snapshot requirement

Take a new consistent etcd snapshot after every preflight passes and immediately
before a control-plane upgrade or other control-plane mutation. An earlier
worker-stage or nightly snapshot is not the control-plane recovery point.

```bash
umask 077
SNAPSHOT_DIR="$HOME/talos-upgrade-backups/$(date -u +%Y%m%dT%H%M%SZ)-pre-rpi-cp-1"
mkdir -p "$SNAPSHOT_DIR"
talosctl --context home-cluster -e 192.168.20.101 -n 192.168.20.101 \
  etcd snapshot "$SNAPSHOT_DIR/etcd-pre-rpi-cp-1.snapshot"
shasum -a 256 "$SNAPSHOT_DIR/etcd-pre-rpi-cp-1.snapshot"
```

The snapshot must be non-empty, report valid snapshot metadata, remain outside
`rpi-cp-1`, and be copied with its checksum and matching machine configuration
to independent storage before the upgrade command is authorized.

## Test a snapshot

This check is non-destructive and runs only on the workstation, never against
the cluster. Work on a copy in a throwaway directory:

```bash
TEST_DIR="$(mktemp -d)"
cp /path/to/etcd-<timestamp>.snapshot /path/to/etcd-<timestamp>.snapshot.sha256 "$TEST_DIR/"
cd "$TEST_DIR"
shasum -a 256 -c etcd-<timestamp>.snapshot.sha256

# Use the etcd image Talos runs:
#   talosctl -e 192.168.20.101 -n 192.168.20.101 get etcdspecs -o yaml | yq '.spec.image'
ETCD_IMAGE="registry.k8s.io/etcd:<version>"
docker run --rm -v "$TEST_DIR":/snap --entrypoint etcdutl "$ETCD_IMAGE" \
  snapshot status /snap/etcd-<timestamp>.snapshot -w table

# Optional: restore into a throwaway data directory under $TEST_DIR.
docker run --rm -v "$TEST_DIR":/snap --entrypoint etcdutl "$ETCD_IMAGE" \
  snapshot restore /snap/etcd-<timestamp>.snapshot --data-dir /snap/restore-test

cd - && rm -rf "$TEST_DIR"
```

A usable snapshot passes the checksum, reports a non-zero revision and key
count, and restores without errors. Do not use `--skip-hash-check`.

## A/B rollback

Talos keeps the previous installation in its A/B boot assets. A failed first
boot should automatically return to the previous version. If the new Talos
version boots and its API is reachable but validation fails, use the client
matching the new version to request rollback of this node only:

```bash
talosctl --context home-cluster -e 192.168.20.101 -n 192.168.20.101 rollback
```

Rollback changes the boot selection and reboots. It is not an etcd, machine
configuration, or application-data backup. If the Talos API or boot chain is
unavailable, recover with physical access and a verified SD image; never write
the recovery image to `/dev/nvme0n1`.

## Recreate and recover etcd

Use disaster recovery only when the original single etcd member cannot be
recovered. Fence the failed control-plane instance, preserve the original SD and
NVMe, and recreate `rpi-cp-1` on an SD card with the same cluster secrets,
address, VIP, and corrected machine configuration.

After the replacement node is in the Talos state required by the version-matched
disaster-recovery procedure (etcd waiting in `Preparing`) and etcd is not
recoverable normally, restore a verified external snapshot with:

```bash
talosctl --context home-cluster -e 192.168.20.101 -n 192.168.20.101 \
  bootstrap --recover-from=/absolute/path/to/etcd-<timestamp>.snapshot
```

Never run normal `bootstrap` or snapshot recovery against the healthy cluster.
Do not skip the snapshot hash check for a normal `talosctl etcd snapshot` file.
After recovery, validate etcd and the Kubernetes API before allowing writers to
resume, then reconcile Kubernetes metadata with the existing Longhorn volume
state.

## Upgrade command pattern

This is documentation only. Run a control-plane upgrade only after a fresh
independent review returns `CONTROL-PLANE REVIEW: GO`. Use the Image Factory
schematic from `install.image` in `nodes.yaml` with the target Talos version
and the matching client:

```bash
IMAGE="factory.talos.dev/metal-installer/<schematic-id>:<target-talos-version>"
talosctl --context home-cluster -e 192.168.20.101 -n 192.168.20.101 \
  upgrade --image "$IMAGE" --reboot-mode=powercycle --wait --timeout=30m
```

Do not manually cordon or drain first. Do not add `--force`, `--stage`, or a
generic installer image. After the upgrade, align `.tool-versions`, the
installer image in `nodes.yaml` and `generate.sh`, and the talosctl image in
`gitops/infra-custom/etcd-backup/cronjob.yaml` with the new version.

## References

- [Talos 1.13 upgrade and A/B rollback](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/lifecycle-management/upgrading-talos)
- [Talos 1.13 etcd backup and disaster recovery](https://docs.siderolabs.com/talos/v1.13/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery)
- [Talos API access from Kubernetes](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/talos-api-access-from-k8s)
