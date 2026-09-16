# Single Control-Plane Recovery

This cluster has one Kubernetes control-plane and one etcd member: `rpi-cp-1`
at `192.168.20.101`. Loss of that node makes the Kubernetes API unavailable,
but worker-hosted workloads and Longhorn data can continue running.

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
TCTL="$HOME/.asdf/installs/talosctl/1.12.8/bin/talosctl"
"$TCTL" --context home-cluster -e 192.168.20.101 -n 192.168.20.101 get systemdisk
"$TCTL" --context home-cluster -e 192.168.20.101 -n 192.168.20.101 \
  get machineconfig v1alpha1 -o json | jq -r .spec | yq '.machine.install'
```

Both disk values must identify `/dev/mmcblk0`. Stop if they differ.

## Protected recovery material

Talos machine configurations contain secrets and must never be committed. The
working recovery bundle is stored outside the repository at:

```text
~/talos-upgrade-backups/20260909T111941Z-control-plane-recovery/
```

It contains:

- the exact live configuration captured before the install-disk correction;
- the exact live configuration after correction to `/dev/mmcblk0`;
- a generated and validated Talos 1.12.12 configuration set using the original
  cluster secret bundle and Kubernetes 1.34.4;
- owner-readable-only Raspberry Pi ARM64 SD images for Talos 1.12.8 and 1.12.12;
- a Talos 1.12.12 client installed alongside the source-version 1.12.8 client.

The external secret bundle remains `~/.talos/homelab/secrets.yaml`. Protect it,
the recovery bundle, talosconfig, kubeconfig, and etcd snapshots as one recovery
set. Keep a second copy on independent storage before control-plane mutation.

## Snapshot requirement

Take a new consistent etcd snapshot after every preflight passes and immediately
before the control-plane upgrade. An earlier worker-stage snapshot is not the
control-plane recovery point.

```bash
umask 077
SNAPSHOT_DIR="$HOME/talos-upgrade-backups/$(date -u +%Y%m%dT%H%M%SZ)-pre-rpi-cp-1"
mkdir -p "$SNAPSHOT_DIR"
TCTL="$HOME/.asdf/installs/talosctl/1.12.8/bin/talosctl"
"$TCTL" --context home-cluster -e 192.168.20.101 -n 192.168.20.101 \
  etcd snapshot "$SNAPSHOT_DIR/etcd-pre-rpi-cp-1.snapshot"
shasum -a 256 "$SNAPSHOT_DIR/etcd-pre-rpi-cp-1.snapshot"
```

The snapshot must be non-empty, report valid snapshot metadata, remain outside
`rpi-cp-1`, and be copied with its checksum and matching machine configuration
to independent storage before the upgrade command is authorized.

## A/B rollback

Talos keeps the previous installation in its A/B boot assets. A failed first
boot should automatically return to the previous version. If Talos 1.12.12
boots and its API is reachable but validation fails, use the matching client to
request rollback of this node only:

```bash
TCTL_NEW="$HOME/.asdf/installs/talosctl/1.12.12/bin/talosctl"
"$TCTL_NEW" --context home-cluster -e 192.168.20.101 -n 192.168.20.101 rollback
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
disaster-recovery procedure and etcd is not recoverable normally, restore the
external snapshot with:

```bash
TCTL_NEW="$HOME/.asdf/installs/talosctl/1.12.12/bin/talosctl"
"$TCTL_NEW" --context home-cluster -e 192.168.20.101 -n 192.168.20.101 \
  bootstrap --recover-from=/absolute/path/to/etcd-pre-rpi-cp-1.snapshot
```

Never run normal `bootstrap` or snapshot recovery against the healthy cluster.
Do not skip the snapshot hash check for a normal `talosctl etcd snapshot` file.
After recovery, validate etcd and the Kubernetes API before allowing writers to
resume, then reconcile Kubernetes metadata with the existing Longhorn volume
state.

## Proposed upgrade command

This is documentation only. Run it only after a fresh independent review returns
`CONTROL-PLANE REVIEW: GO`:

```bash
TCTL="$HOME/.asdf/installs/talosctl/1.12.8/bin/talosctl"
IMAGE="factory.talos.dev/metal-installer/5199ca37666edc3419ae8e1cfe49bdd89f1b5b2995e0078abaa9d710871b6751:v1.12.12"
"$TCTL" --context home-cluster -e 192.168.20.101 -n 192.168.20.101 \
  upgrade --image "$IMAGE" --reboot-mode=powercycle --wait --timeout=30m
```

Do not manually cordon or drain first. Do not add `--force`, `--stage`, or a
generic installer image.

## References

- [Talos 1.12 upgrade and A/B rollback](https://docs.siderolabs.com/talos/v1.12/configure-your-talos-cluster/lifecycle-management/upgrading-talos)
- [Talos 1.12 etcd backup and disaster recovery](https://docs.siderolabs.com/talos/v1.12/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery)
