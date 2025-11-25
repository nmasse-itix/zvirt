# Zvirt = Libvirt ZFS snapshots

## Purpose

Zvirt takes snapshots of Libvirt domains using ZFS.
It supports both crash-consistent and live snapshots.

At the end, all components of a domain - Domain definition, TPM, NVRAM, VirtioFS, disks (either files on a ZFS dataset or raw zvols) - are captured as a set of consistent ZFS snapshots.

## Features

- Take snapshots of Libvirt domains using ZFS.
- Support both crash-consistent and live snapshots.
- Support batch mode (pause all domains, take snapshots, then resume all domains)

## License

MIT License

## Author

Nicolas Massé
