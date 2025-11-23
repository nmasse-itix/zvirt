#!/usr/bin/env bats

setup() {
  bats_load_library 'bats-support'
  bats_load_library 'bats-assert'

  set -Eeuo pipefail
  export LANG=C LC_ALL=C

  zvirt () {
    "${BATS_TEST_DIRNAME}/../../src/zvirt" "$@"
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
    #echo "qemu_exec: command output: $output" >&3
    pid="$(echo "$output" | jq -r '.return.pid')"
    if [ -z "$pid" ] || [ "$pid" == "null" ]; then
      echo "qemu_exec: failed to get pid from command output" >&3
      return 1
    fi
    sleep .25
    while true; do
      local status_command="{\"execute\": \"guest-exec-status\", \"arguments\": {\"pid\": $pid}}"
      status_output="$(virsh qemu-agent-command "$domain" "$status_command")"
      #echo "qemu_exec: status output: $status_output" >&3
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
    echo "teardown: Cleaning up created domains and images..." >&3
    for domain in standard with-fs with-zvol; do
      if virsh dominfo "$domain" &>/dev/null; then
        virsh destroy "$domain" || true
        virsh undefine "$domain" --nvram || true
      fi
      zfs destroy -r data/domains/"$domain" || true
      rm -rf "/var/lib/libvirt/images/${domain}"
    done
  }

  create_domains() {
    # Create the standard VM
    echo "setup: Creating the standard VM..." >&3
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
    echo "setup: Creating the with-fs VM..." >&3
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
    echo "setup: Creating the with-zvol VM..." >&3
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
    echo "setup: Waiting for VMs to become ready..." >&3
    for domain in standard with-fs with-zvol; do
      echo "setup: Waiting for qemu guest agent to be running in domain '$domain'..." >&3
      until virsh qemu-agent-command "$domain" '{"execute":"guest-ping"}' &>/dev/null; do
        sleep 2
      done
    done
    echo "setup: all VMs started successfully" >&3
    for domain in standard with-fs with-zvol; do
      echo "setup: Waiting for cloud-init to complete in domain '$domain'..." >&3
      until qemu_exec "$domain" test -f /var/lib/cloud/instance/boot-finished; do
        sleep 2
      done
    done
    echo "setup: VMs are ready" >&3
  }

  local fedora_url="https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2"
  local fedora_img="/var/lib/libvirt/images/$(basename "$fedora_url")"
  if [ ! -f "$fedora_img" ]; then
    echo "setup: downloading Fedora Cloud image to $fedora_img" >&3
    mkdir -p /var/lib/libvirt/images/library
    curl -sSfL -o "$fedora_img" "$fedora_url"
  fi
  echo "setup: Fedora Cloud image is at $fedora_img" >&3

  # Cleanup any leftover artifacts from previous runs
  cleanup
  create_domains
  readiness_wait
}

teardown() {
  cleanup
}

@test "zvirt: setup selftest" {
  echo "setup: provisioning completed" >&3
}

@test "zvirt: take live snapshot in batch mode" {
  # Create witness files in all three domains before taking snapshots
  qemu_exec standard touch /test/rootfs/before-backup1
  qemu_exec with-fs touch /test/rootfs/before-backup1
  qemu_exec with-zvol touch /test/zvol/before-backup1
  [[ -f /srv/with-fs/before-backup1 ]]

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
  assert_output "before-backup1"
  run qemu_exec with-fs ls -1 /test/rootfs
  assert_success
  assert_output "before-backup1"
  run qemu_exec with-zvol ls -1 /test/zvol
  assert_success
  assert_output "before-backup1"

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
}


# @test "call_parse_args: take a crash-consistent snapshot for two domains" {
#   run zvirt snapshot -d standard -d with-zvol -d with-fs backup2
#   assert_success
# }

# @test "call_parse_args: revert snapshot for a domain" {
#   virsh destroy standard || true
#   run zvirt revert -d standard -s backup2
#   assert_success
# }

# @test "call_parse_args: revert snapshot for all domains in batch mode" {
#   virsh destroy standard || true
#   virsh destroy with-zvol || true
#   virsh destroy with-fs || true
#   run zvirt revert -b -d standard -d with-zvol -d with-fs -s backup1
#   assert_success
# }

