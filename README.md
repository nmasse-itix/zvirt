# Zvirt = Libvirt ZFS snapshots

## Purpose

Zvirt takes snapshots of Libvirt domains using ZFS.
It supports both crash-consistent and live snapshots.

At the end, all components of a domain - Domain definition, TPM, NVRAM, VirtioFS, disks (either files on a ZFS dataset or raw zvols) - are captured as a set of consistent ZFS snapshots.

## Features

- Take snapshots of Libvirt domains using ZFS.
- Support both crash-consistent and live snapshots.
- Support batch mode (pause all domains, take snapshots, then resume all domains)

## Snapshot retention

`snapshot-libvirt-domains` runs `zfs-autobackup` with `--no-thinning`: it only creates snapshots and
never deletes any. Retention is left to a separate `zfs-autobackup` run in snapshot-only mode:

```console
$ zfs-autobackup --no-snapshot --keep-source 1w1d,1m1w,1y1m \
                 --snapshot-format "$(snapshot-libvirt-domains --print-snapshot-format)" libvirt
```

That run **must** be given the very same snapshot name format zvirt snapshotted with: `zfs-autobackup`
only thins snapshots whose name parses against the format it was given. On a mismatch it selects the
right datasets, matches none of their snapshots, deletes nothing and still exits 0 with
`All operations completed successfully` — so never hardcode the format, always query it.

Two ways to query it:

```console
$ snapshot-libvirt-domains --print-snapshot-format
libvirt-%Y-%m-%d-%H:%M:%S

$ . /usr/share/zvirt/snapshot-format && echo "$ZVIRT_SNAPSHOT_FORMAT"
libvirt-%Y-%m-%d-%H:%M:%S
```

`/usr/share/zvirt/snapshot-format` is the single source of truth: `snapshot-libvirt-domains` sources
it too, so the format cannot drift between the tool that writes the snapshots and the tool that
prunes them.

The format deliberately carries no `{}` placeholder (`zfs-autobackup`'s default is
`{}-%Y%m%d%H%M%S`, where `{}` expands to the backup name). All domains therefore share a single
snapshot name pattern, which is what allows one prune run over the shared `autobackup:libvirt`
property to cover every domain at once, instead of one invocation per domain.

### Pruning from a systemd unit

`%Y`, `%m`, `%d`, `%H`, `%M` and `%S` are systemd specifiers: written literally in an `ExecStart=`
they are silently expanded into paths and hostnames, and `systemd-analyze verify` does not catch it.
Either double them (`%%Y`, `%%m`, ...) or — better — let the unit call a wrapper that queries the
format:

```ini
ExecStart=/bin/bash -c '. /usr/share/zvirt/snapshot-format; exec /usr/bin/zfs-autobackup --no-snapshot --keep-source 1w1d,1m1w,1y1m --snapshot-format "$ZVIRT_SNAPSHOT_FORMAT" libvirt'
```

## License

MIT License

## Author

Nicolas Massé
