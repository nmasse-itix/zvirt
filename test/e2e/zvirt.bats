#!/usr/bin/env bats

setup() {
  bats_load_library 'bats-support'
  bats_load_library 'bats-assert'

  set -Eeuo pipefail
  export LANG=C LC_ALL=C

  zvirt () {
    "${BATS_TEST_DIRNAME}/../../src/bin/zvirt" "$@"
  }

  declare -g e2e_test_enable_debug=1
  e2e_test_debug_log(){
    if [ "$e2e_test_enable_debug" -eq 1 ]; then
      echo "$@" >&3
    fi
  }

  qemu_exec() {
    domain="$1"
    shift || true
    local json_args=""
    for arg in "${@:2}"; do
      if [ -n "$json_args" ]; then
        json_args+=", "
      fi
      json_args+="\"$arg\""
    done
    local command="{\"execute\": \"guest-exec\", \"arguments\": {\"path\": \"$1\", \"arg\": [ $json_args ], \"capture-output\": true }}"
    output="$(virsh qemu-agent-command "$domain" "$command")"
    #e2e_test_debug_log "qemu_exec: command output: $output"
    pid="$(echo "$output" | jq -r '.return.pid')"
    if [ -z "$pid" ] || [ "$pid" == "null" ]; then
      e2e_test_debug_log "qemu_exec: failed to get pid from command output"
      return 1
    fi
    sleep .25
    while true; do
      local status_command="{\"execute\": \"guest-exec-status\", \"arguments\": {\"pid\": $pid}}"
      status_output="$(virsh qemu-agent-command "$domain" "$status_command")"
      #e2e_test_debug_log "qemu_exec: status output: $status_output"
      exited="$(echo "$status_output" | jq -r '.return.exited')"
      if [ "$exited" == "true" ]; then
        stdout_base64="$(echo "$status_output" | jq -r '.return["out-data"]')"
        if [ "$stdout_base64" != "null" ]; then
          echo "$stdout_base64" | base64 --decode
        fi
        stderr_base64="$(echo "$status_output" | jq -r '.return["err-data"]')"
        if [ "$stderr_base64" != "null" ]; then
          echo "$stderr_base64" | base64 --decode >&2
        fi
        exit_code="$(echo "$status_output" | jq -r '.return.exitcode')"
        return $exit_code
      fi
      sleep 1
    done
  }

  create_cloud_init_iso () {
    local domain="$1"
    local iso_path="/var/lib/libvirt/images/${domain}/cloud-init.iso"
    local user_data_path="/var/lib/libvirt/images/${domain}/cloud-init/user-data"
    local meta_data_path="/var/lib/libvirt/images/${domain}/cloud-init/meta-data"

    # Create cloud-init user-data and meta-data files
    mkdir -p "/var/lib/libvirt/images/${domain}/cloud-init"
    cp "${BATS_TEST_DIRNAME}/cloud-init/${domain}-user-data" "$user_data_path"
    cat > "$meta_data_path" <<EOF
instance-id: ${domain}
local-hostname: ${domain}
EOF
    
    # Create ISO image
    genisoimage -output "$iso_path" -volid cidata -joliet -rock "$user_data_path" "$meta_data_path"
  }

  convert_cloud_image() {
    local src="$1"
    local dest="$2"
    
    # Convert qcow2 to raw and resize to 20G
    qemu-img convert -f qcow2 -O raw "$src" "$dest"
    qemu-img resize -f raw "$dest" 20G
  }

  cleanup() {
    e2e_test_debug_log "teardown: Cleaning up created domains and images..."
    for domain in standard with-fs with-zvol; do
      state="$(virsh domstate "$domain" 2>/dev/null || true)"
      if [[ -n "$state" && "$state" != "shut off" ]]; then
        virsh destroy "$domain"
      fi
      if virsh dominfo "$domain" &>/dev/null; then
        virsh undefine "$domain" --nvram
      fi
    done
    sleep 1
    sync
    sleep 1
    for domain in standard with-fs with-zvol; do
      if zfs list data/domains/"$domain" &>/dev/null; then
        zfs destroy -rR data/domains/"$domain"
      fi
      sleep .2
      rm -rf "/var/lib/libvirt/images/${domain}"
    done
  }

  create_domains() {
    # Create the standard VM
    e2e_test_debug_log "setup: Creating the standard VM..."
    mkdir -p /var/lib/libvirt/images/standard
    zfs create -p data/domains/standard -o mountpoint=/var/lib/libvirt/images/standard
    convert_cloud_image "$fedora_img" "/var/lib/libvirt/images/standard/root.img"
    create_cloud_init_iso "standard"
    virt-install  --noautoconsole \
                  --name=standard \
                  --cpu=host-passthrough \
                  --vcpus=1 \
                  --ram=4096 \
                  --os-variant=fedora-rawhide \
                  --disk=path=/var/lib/libvirt/images/standard/root.img,target.dev=vda,bus=virtio,driver.discard=unmap,driver.io=io_uring,format=raw,sparse=True,blockio.logical_block_size=512,blockio.physical_block_size=512,serial=root,format=raw \
                  --network=none \
                  --console=pty,target.type=virtio \
                  --serial=pty \
                  --disk=path=/var/lib/libvirt/images/standard/cloud-init.iso,readonly=True \
                  --import \
                  --sysinfo=system.serial=ds=nocloud \
                  --boot=uefi

    # Create the with-fs VM
    e2e_test_debug_log "setup: Creating the with-fs VM..."
    mkdir -p /var/lib/libvirt/images/with-fs /srv/with-fs
    chmod 0777 /srv/with-fs
    zfs create -p data/domains/with-fs -o mountpoint=/var/lib/libvirt/images/with-fs
    zfs create -p data/domains/with-fs/virtiofs -o mountpoint=/srv/with-fs
    convert_cloud_image "$fedora_img" "/var/lib/libvirt/images/with-fs/root.img"
    create_cloud_init_iso "with-fs"
    virt-install  --noautoconsole \
                  --name=with-fs \
                  --cpu=host-passthrough \
                  --vcpus=1 \
                  --ram=4096 \
                  --os-variant=fedora-rawhide \
                  --disk=path=/var/lib/libvirt/images/with-fs/root.img,target.dev=vda,bus=virtio,driver.discard=unmap,driver.io=io_uring,format=raw,sparse=True,blockio.logical_block_size=512,blockio.physical_block_size=512,serial=root,format=raw \
                  --network=none \
                  --console=pty,target.type=virtio \
                  --serial=pty \
                  --disk=path=/var/lib/libvirt/images/with-fs/cloud-init.iso,readonly=True \
                  --import \
                  --sysinfo=system.serial=ds=nocloud \
                  --boot=uefi \
                  --memorybacking=access.mode=shared,source.type=memfd \
                  --filesystem=type=mount,accessmode=passthrough,driver.type=virtiofs,driver.queue=1024,source.dir=/srv/with-fs,target.dir=data

    # Create the with-zvol VM
    e2e_test_debug_log "setup: Creating the with-zvol VM..."
    mkdir -p /var/lib/libvirt/images/with-zvol
    zfs create -p data/domains/with-zvol -o mountpoint=/var/lib/libvirt/images/with-zvol
    zfs create -V 10G data/domains/with-zvol/data
    convert_cloud_image "$fedora_img" "/var/lib/libvirt/images/with-zvol/root.img"
    create_cloud_init_iso "with-zvol"
    virt-install  --noautoconsole \
                  --name=with-zvol \
                  --cpu=host-passthrough \
                  --vcpus=1 \
                  --ram=4096 \
                  --os-variant=fedora-rawhide \
                  --disk=path=/var/lib/libvirt/images/with-zvol/root.img,target.dev=vda,bus=virtio,driver.discard=unmap,driver.io=io_uring,format=raw,sparse=True,blockio.logical_block_size=512,blockio.physical_block_size=512,serial=root,format=raw \
                  --disk=path=/dev/zvol/data/domains/with-zvol/data,target.dev=vdb,bus=virtio,cache=directsync,blockio.logical_block_size=4096,blockio.physical_block_size=4096,driver.discard=unmap,driver.io=io_uring,serial=zvol \
                  --network=none \
                  --console=pty,target.type=virtio \
                  --serial=pty \
                  --disk=path=/var/lib/libvirt/images/with-zvol/cloud-init.iso,readonly=True \
                  --import \
                  --sysinfo=system.serial=ds=nocloud \
                  --boot=uefi
  }

  readiness_wait() {
    e2e_test_debug_log "setup: Waiting for VMs to become ready..."
    for domain in standard with-fs with-zvol; do
      e2e_test_debug_log "setup: Waiting for qemu guest agent to be running in domain '$domain'..."
      until virsh qemu-agent-command "$domain" '{"execute":"guest-ping"}' &>/dev/null; do
        sleep 2
      done
    done
    e2e_test_debug_log "setup: all VMs started successfully"
    for domain in standard with-fs with-zvol; do
      e2e_test_debug_log "setup: Waiting for cloud-init to complete in domain '$domain'..."
      until qemu_exec "$domain" test -f /var/lib/cloud/instance/boot-finished; do
        sleep 2
      done
    done
    if ! qemu_exec with-fs grep -q /test/virtiofs /proc/mounts; then
      e2e_test_debug_log "setup: virtiofs not mounted in 'with-fs' domain"
      return 1
    fi
    if ! qemu_exec with-zvol grep -q /test/zvol /proc/mounts; then
      e2e_test_debug_log "setup: zvol not mounted in 'with-zvol' domain"
      return 1
    fi
    e2e_test_debug_log "setup: VMs are ready"
  }

  local fedora_url="https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2"
  local fedora_img="/var/lib/libvirt/images/$(basename "$fedora_url")"
  if [ ! -f "$fedora_img" ]; then
    e2e_test_debug_log "setup: downloading Fedora Cloud image to $fedora_img"
    mkdir -p /var/lib/libvirt/images/library
    curl -sSfL -o "$fedora_img" "$fedora_url"
  fi
  e2e_test_debug_log "setup: Fedora Cloud image is at $fedora_img"

  # Cleanup any leftover artifacts from previous runs
  cleanup
  create_domains
  readiness_wait
}

teardown() {
  cleanup
}

@test "zvirt: setup selftest" {
  e2e_test_debug_log "setup: provisioning completed"
}

@test "zvirt: prune snapshots" {
  # Take five snapshots in a row, each time creating and deleting a witness file
  for snap in s1 s2 s3 s4 s5; do
    # Create witness files in all three domains before taking snapshots
    qemu_exec standard touch /test/rootfs/witness-file.$snap
    qemu_exec with-fs touch /test/virtiofs/witness-file.$snap
    qemu_exec with-zvol touch /test/zvol/witness-file.$snap

    # Verify that the witness files exist in the virtiofs host mount
    run test -f /srv/with-fs/witness-file.$snap
    assert_success

    # Take crash-consistent snapshots for all three domains
    run zvirt snapshot -d standard -d with-zvol -d with-fs -s $snap
    assert_success

    # Verify that the domains are still running
    run virsh domstate standard
    assert_success
    assert_output "running"
    run virsh domstate with-fs
    assert_success
    assert_output "running"
    run virsh domstate with-zvol
    assert_success
    assert_output "running"

    # Assert that the files created before the snapshot exist
    run qemu_exec standard ls -1 /test/rootfs
    assert_success
    assert_output "witness-file.$snap"
    run qemu_exec with-fs ls -1 /test/virtiofs
    assert_success
    assert_output "witness-file.$snap"
    run qemu_exec with-zvol ls -1 /test/zvol
    assert_success
    assert_output "witness-file.$snap"

    # Delete the witness files
    run qemu_exec standard rm /test/rootfs/witness-file.$snap
    assert_success
    run qemu_exec with-fs rm /test/virtiofs/witness-file.$snap
    assert_success
    run qemu_exec with-zvol rm /test/zvol/witness-file.$snap
    assert_success

    # Sync all filesystems
    run qemu_exec standard sync
    assert_success
    run qemu_exec with-fs sync
    assert_success
    run qemu_exec with-zvol sync
    assert_success

    # Wait a moment to ensure all writes are flushed
    sleep 2

    # Verify that the witness files have been deleted in the virtiofs host mount
    run test -f /srv/with-fs/witness-file.$snap
    assert_failure
  done

  # List snapshots and verify their existence
  run zvirt list -d standard -d with-zvol -d with-fs
  assert_success
  assert_output "Snapshots for domain 'standard':
  - s1
  - s2
  - s3
  - s4
  - s5
Snapshots for domain 'with-zvol':
  - s1
  - s2
  - s3
  - s4
  - s5
Snapshots for domain 'with-fs':
  - s1
  - s2
  - s3
  - s4
  - s5"

  # Prune snapshots to keep only the latest two
  run zvirt prune -k 2 -d standard -d with-zvol -d with-fs
  assert_success

  # List snapshots and verify their existence
  run zvirt list -d standard -d with-zvol -d with-fs
  assert_success
  assert_output "Snapshots for domain 'standard':
  - s4
  - s5
Snapshots for domain 'with-zvol':
  - s4
  - s5
Snapshots for domain 'with-fs':
  - s4
  - s5"

  # Stop all domains
  run virsh destroy standard
  assert_success
  run virsh destroy with-fs
  assert_success
  run virsh destroy with-zvol
  assert_success

  # Revert snapshots in batch mode
  run zvirt revert -d standard -d with-zvol -d with-fs -s s4
  assert_success

  # Check all domains have been shut off
  run virsh domstate standard
  assert_success
  assert_output "shut off"
  run virsh domstate with-fs
  assert_success
  assert_output "shut off"
  run virsh domstate with-zvol
  assert_success
  assert_output "shut off"

  # Start all domains
  run virsh start standard
  assert_success
  run virsh start with-fs
  assert_success
  run virsh start with-zvol
  assert_success

  # Wait for all domains to be fully ready
  readiness_wait

  # Verify that the witness files still exist after revert
  run qemu_exec standard ls -1 /test/rootfs
  assert_success
  assert_output "witness-file.s4"
  run qemu_exec with-fs ls -1 /test/virtiofs
  assert_success
  assert_output "witness-file.s4"
  run qemu_exec with-zvol ls -1 /test/zvol
  assert_success
  assert_output "witness-file.s4"
}

@test "zvirt: take live snapshot in batch mode" {
  # Create witness files in all three domains before taking snapshots
  qemu_exec standard touch /test/rootfs/witness-file
  qemu_exec with-fs touch /test/virtiofs/witness-file
  qemu_exec with-zvol touch /test/zvol/witness-file

  # Verify that the witness files exist in the virtiofs host mount
  run test -f /srv/with-fs/witness-file
  assert_success

  # Take live snapshots for all three domains
  run zvirt snapshot -b -d standard -d with-zvol -d with-fs -s backup1 -l
  assert_success

  # Verify that the domains are still running
  run virsh domstate standard
  assert_success
  assert_output "running"
  run virsh domstate with-fs
  assert_success
  assert_output "running"
  run virsh domstate with-zvol
  assert_success
  assert_output "running"

  # Assert that the files created before the snapshot exist
  run qemu_exec standard ls -1 /test/rootfs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-fs ls -1 /test/virtiofs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-zvol ls -1 /test/zvol
  assert_success
  assert_output "witness-file"

  # List snapshots and verify their existence
  run zvirt list -d standard -d with-zvol -d with-fs
  assert_success
  assert_output "Snapshots for domain 'standard':
  - backup1
Snapshots for domain 'with-zvol':
  - backup1
Snapshots for domain 'with-fs':
  - backup1"

  # Attempt to take the same snapshot again and expect failure
  run zvirt snapshot -b -d standard -d with-zvol -d with-fs -s backup1 -l
  assert_failure
  assert_output --partial "Snapshot 'backup1' already exists."
  assert_output --partial "standard:"
  assert_output --partial "with-zvol:"
  assert_output --partial "with-fs:"
  assert_output --partial "Pre-flight checks failed."

  # Delete the witness files
  run qemu_exec standard rm /test/rootfs/witness-file
  assert_success
  run qemu_exec with-fs rm /test/virtiofs/witness-file
  assert_success
  run qemu_exec with-zvol rm /test/zvol/witness-file
  assert_success

  # Sync all filesystems
  run qemu_exec standard sync
  assert_success
  run qemu_exec with-fs sync
  assert_success
  run qemu_exec with-zvol sync
  assert_success

  # Verify that the witness files have been deleted in the virtiofs host mount
  run test -f /srv/with-fs/witness-file
  assert_failure

  # Stop all domains
  run virsh destroy standard
  assert_success
  run virsh destroy with-fs
  assert_success
  run virsh destroy with-zvol
  assert_success

  # Revert snapshots in batch mode
  run zvirt revert -b -d standard -d with-zvol -d with-fs -s backup1
  assert_success

  # Check all domains are running again
  run virsh domstate standard
  assert_success
  assert_output "running"
  run virsh domstate with-fs
  assert_success
  assert_output "running"
  run virsh domstate with-zvol
  assert_success
  assert_output "running"

  # Verify that the witness files still exist after revert
  run qemu_exec standard ls -1 /test/rootfs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-fs ls -1 /test/virtiofs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-zvol ls -1 /test/zvol
  assert_success
  assert_output "witness-file"
}

@test "zvirt: take live snapshot without batch mode" {
  # Create witness files in all three domains before taking snapshots
  qemu_exec standard touch /test/rootfs/witness-file
  qemu_exec with-fs touch /test/virtiofs/witness-file
  qemu_exec with-zvol touch /test/zvol/witness-file

  # Verify that the witness files exist in the virtiofs host mount
  run test -f /srv/with-fs/witness-file
  assert_success

  # Take live snapshots for all three domains
  run zvirt snapshot -d standard -d with-zvol -d with-fs -s backup1 -l
  assert_success

  # Verify that the domains are still running
  run virsh domstate standard
  assert_success
  assert_output "running"
  run virsh domstate with-fs
  assert_success
  assert_output "running"
  run virsh domstate with-zvol
  assert_success
  assert_output "running"

  # Assert that the files created before the snapshot exist
  run qemu_exec standard ls -1 /test/rootfs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-fs ls -1 /test/virtiofs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-zvol ls -1 /test/zvol
  assert_success
  assert_output "witness-file"

  # List snapshots and verify their existence
  run zvirt list -d standard -d with-zvol -d with-fs
  assert_success
  assert_output "Snapshots for domain 'standard':
  - backup1
Snapshots for domain 'with-zvol':
  - backup1
Snapshots for domain 'with-fs':
  - backup1"

  # Attempt to take the same snapshot again and expect failure
  run zvirt snapshot -d standard -d with-zvol -d with-fs -s backup1 -l
  assert_failure
  assert_output --partial "Snapshot 'backup1' already exists."
  assert_output --partial "standard:"
  assert_output --partial "with-zvol:"
  assert_output --partial "with-fs:"
  assert_output --partial "Pre-flight checks failed."

  # Delete the witness files
  run qemu_exec standard rm /test/rootfs/witness-file
  assert_success
  run qemu_exec with-fs rm /test/virtiofs/witness-file
  assert_success
  run qemu_exec with-zvol rm /test/zvol/witness-file
  assert_success

  # Sync all filesystems
  run qemu_exec standard sync
  assert_success
  run qemu_exec with-fs sync
  assert_success
  run qemu_exec with-zvol sync
  assert_success

  # Verify that the witness files have been deleted in the virtiofs host mount
  run test -f /srv/with-fs/witness-file
  assert_failure

  # Stop all domains
  run virsh destroy standard
  assert_success
  run virsh destroy with-fs
  assert_success
  run virsh destroy with-zvol
  assert_success

  # Revert snapshots in batch mode
  run zvirt revert -d standard -d with-zvol -d with-fs -s backup1
  assert_success

  # Check all domains are running again
  run virsh domstate standard
  assert_success
  assert_output "running"
  run virsh domstate with-fs
  assert_success
  assert_output "running"
  run virsh domstate with-zvol
  assert_success
  assert_output "running"

  # Verify that the witness files still exist after revert
  run qemu_exec standard ls -1 /test/rootfs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-fs ls -1 /test/virtiofs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-zvol ls -1 /test/zvol
  assert_success
  assert_output "witness-file"
}

@test "zvirt: take crash-consistent snapshot without batch mode" {
  # Create witness files in all three domains before taking snapshots
  qemu_exec standard touch /test/rootfs/witness-file
  qemu_exec with-fs touch /test/virtiofs/witness-file
  qemu_exec with-zvol touch /test/zvol/witness-file

  # Verify that the witness files exist in the virtiofs host mount
  run test -f /srv/with-fs/witness-file
  assert_success

  # Take crash-consistent snapshots for all three domains
  run zvirt snapshot -d standard -d with-zvol -d with-fs -s backup1
  assert_success

  # Verify that the domains are still running
  run virsh domstate standard
  assert_success
  assert_output "running"
  run virsh domstate with-fs
  assert_success
  assert_output "running"
  run virsh domstate with-zvol
  assert_success
  assert_output "running"

  # Assert that the files created before the snapshot exist
  run qemu_exec standard ls -1 /test/rootfs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-fs ls -1 /test/virtiofs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-zvol ls -1 /test/zvol
  assert_success
  assert_output "witness-file"

  # List snapshots and verify their existence
  run zvirt list -d standard -d with-zvol -d with-fs
  assert_success
  assert_output "Snapshots for domain 'standard':
  - backup1
Snapshots for domain 'with-zvol':
  - backup1
Snapshots for domain 'with-fs':
  - backup1"

  # Attempt to take the same snapshot again and expect failure
  run zvirt snapshot -d standard -d with-zvol -d with-fs -s backup1
  assert_failure
  assert_output --partial "Snapshot 'backup1' already exists."
  assert_output --partial "standard:"
  assert_output --partial "with-zvol:"
  assert_output --partial "with-fs:"
  assert_output --partial "Pre-flight checks failed."

  # Delete the witness files
  run qemu_exec standard rm /test/rootfs/witness-file
  assert_success
  run qemu_exec with-fs rm /test/virtiofs/witness-file
  assert_success
  run qemu_exec with-zvol rm /test/zvol/witness-file
  assert_success

  # Sync all filesystems
  run qemu_exec standard sync
  assert_success
  run qemu_exec with-fs sync
  assert_success
  run qemu_exec with-zvol sync
  assert_success

  # Wait a moment to ensure all writes are flushed
  sleep 2

  # Verify that the witness files have been deleted in the virtiofs host mount
  run test -f /srv/with-fs/witness-file
  assert_failure

  # Stop all domains
  run virsh destroy standard
  assert_success
  run virsh destroy with-fs
  assert_success
  run virsh destroy with-zvol
  assert_success

  # Revert snapshots in batch mode
  run zvirt revert -d standard -d with-zvol -d with-fs -s backup1
  assert_success

  # Check all domains have been shut off
  run virsh domstate standard
  assert_success
  assert_output "shut off"
  run virsh domstate with-fs
  assert_success
  assert_output "shut off"
  run virsh domstate with-zvol
  assert_success
  assert_output "shut off"

  # Start all domains
  run virsh start standard
  assert_success
  run virsh start with-fs
  assert_success
  run virsh start with-zvol
  assert_success

  # Wait for all domains to be fully ready
  readiness_wait

  # Verify that the witness files still exist after revert
  run qemu_exec standard ls -1 /test/rootfs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-fs ls -1 /test/virtiofs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-zvol ls -1 /test/zvol
  assert_success
  assert_output "witness-file"
}

@test "zvirt: take crash-consistent snapshot with batch mode" {
  # Create witness files in all three domains before taking snapshots
  qemu_exec standard touch /test/rootfs/witness-file
  qemu_exec with-fs touch /test/virtiofs/witness-file
  qemu_exec with-zvol touch /test/zvol/witness-file

  # Verify that the witness files exist in the virtiofs host mount
  run test -f /srv/with-fs/witness-file
  assert_success

  # Take crash-consistent snapshots for all three domains
  run zvirt snapshot -b -d standard -d with-zvol -d with-fs -s backup1
  assert_success

  # Verify that the domains are still running
  run virsh domstate standard
  assert_success
  assert_output "running"
  run virsh domstate with-fs
  assert_success
  assert_output "running"
  run virsh domstate with-zvol
  assert_success
  assert_output "running"

  # Assert that the files created before the snapshot exist
  run qemu_exec standard ls -1 /test/rootfs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-fs ls -1 /test/virtiofs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-zvol ls -1 /test/zvol
  assert_success
  assert_output "witness-file"

  # List snapshots and verify their existence
  run zvirt list -d standard -d with-zvol -d with-fs
  assert_success
  assert_output "Snapshots for domain 'standard':
  - backup1
Snapshots for domain 'with-zvol':
  - backup1
Snapshots for domain 'with-fs':
  - backup1"

  # Attempt to take the same snapshot again and expect failure
  run zvirt snapshot -b -d standard -d with-zvol -d with-fs -s backup1
  assert_failure
  assert_output --partial "Snapshot 'backup1' already exists."
  assert_output --partial "standard:"
  assert_output --partial "with-zvol:"
  assert_output --partial "with-fs:"
  assert_output --partial "Pre-flight checks failed."

  # Delete the witness files
  run qemu_exec standard rm /test/rootfs/witness-file
  assert_success
  run qemu_exec with-fs rm /test/virtiofs/witness-file
  assert_success
  run qemu_exec with-zvol rm /test/zvol/witness-file
  assert_success

  # Sync all filesystems
  run qemu_exec standard sync
  assert_success
  run qemu_exec with-fs sync
  assert_success
  run qemu_exec with-zvol sync
  assert_success

  # Wait a moment to ensure all writes are flushed
  sleep 2

  # Verify that the witness files have been deleted in the virtiofs host mount
  run test -f /srv/with-fs/witness-file
  assert_failure

  # Stop all domains
  run virsh destroy standard
  assert_success
  run virsh destroy with-fs
  assert_success
  run virsh destroy with-zvol
  assert_success

  # Revert snapshots in batch mode
  run zvirt revert -b -d standard -d with-zvol -d with-fs -s backup1
  assert_success

  # Check all domains are running again
  run virsh domstate standard
  assert_success
  assert_output "running"
  run virsh domstate with-fs
  assert_success
  assert_output "running"
  run virsh domstate with-zvol
  assert_success
  assert_output "running"

  # Wait for all domains to be fully ready
  readiness_wait

  # Verify that the witness files still exist after revert
  run qemu_exec standard ls -1 /test/rootfs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-fs ls -1 /test/virtiofs
  assert_success
  assert_output "witness-file"
  run qemu_exec with-zvol ls -1 /test/zvol
  assert_success
  assert_output "witness-file"
}
