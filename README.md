# Zvirt = Libvirt ZFS snapshots

## Purpose

Zvirt takes snapshots of Libvirt domains using ZFS.
It supports both crash-consistent and live snapshots.

At the end, all components of a domain - Domain definition, TPM, NVRAM, VirtioFS, disks (either files on a ZFS dataset or raw zvols) - are captured as a set of consistent ZFS snapshots.

## Features

- Take snapshots of Libvirt domains using ZFS.
- Support both crash-consistent and live snapshots.
- Support batch mode (pause all domains, take snapshots, then resume all domains)

## Selecting the domains to snapshot

`snapshot-libvirt-domains` iterates over the libvirt domains and hands each one to `zfs-autobackup`
under the backup name `libvirt-<domain>`, that is, the ZFS property `autobackup:libvirt-<domain>`.
Which datasets that property selects is `zfs-autobackup`'s decision, not zvirt's: it looks the
property up on every dataset, resolves inheritance, and tests its **value**:

| Value    | Selected                                         |
| -------- | ------------------------------------------------ |
| `true`   | yes, on the dataset and everything inheriting it  |
| `false`  | no, explicitly excluded                           |
| `child`  | only the datasets that *inherit* it, not this one |
| `parent` | only this dataset, not the ones inheriting it     |

Inherited properties count, so the whole fleet can be configured on the parent dataset of all the
domains:

```console
$ zfs set autobackup:libvirt-quay=true data/domains/quay   # this domain and its children
$ zfs set autobackup:libvirt=true data/domains             # the shared property, for pruning
```

A domain that carries the property nowhere is skipped with a message on stderr and the run carries
on with the next one, exiting 0 — configuring only some domains is a legitimate setup.

> [!WARNING]
> The property selects **datasets**, not domains, and zvirt does not check that the selection
> actually covers a domain's storage. Set it on the domain's root dataset — set on a child only, the
> run reports success while the disks above it are never snapshotted. `zfs-autobackup --test
> --no-send --no-thinning libvirt-<domain>` prints the datasets it would select.

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
