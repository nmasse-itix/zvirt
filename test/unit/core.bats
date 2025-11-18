#!/usr/bin/env bats

setup() {
  bats_load_library 'bats-support'
  bats_load_library 'bats-assert'
  bats_load_library 'bats-mock'

  # Load the core library and export its functions
  local fn_before="$(declare -F | cut -d ' ' -f 3 | sort)"
  set -Eeuo pipefail
  source "${BATS_TEST_DIRNAME}/../../src/lib/core.sh"
  local fn_after="$(declare -F | cut -d ' ' -f 3 | sort)"
  declare -a zvirt_fn=( $(comm -13 <(echo "$fn_before") <(echo "$fn_after")) )
  for fn in "${zvirt_fn[@]}"; do
    export -f "${fn}"
  done

  # Helper to run commands in a separate bash process with the proper flags
  # and with access to the domain_params_cache associative array
  in_bash() {
    local vars=""
    for var in domain_params_cache snapshot_name domains verbose action batch live; do
      if declare -p "${var}" &>/dev/null; then
        vars+="$(declare -p "${var}") ; "
      fi
    done
    bash -Eeuo pipefail -c "init_global_variables ; $vars \"\$@\"" zvirt "$@"
  }

}

@test "domain_state: nominal case" {
  # Mock the underlying tools
  virsh() {
    [[ "$*" == "domstate foo" ]] && echo "running"
  }
  export -f virsh

  # Run the test
  run in_bash domain_state "foo"
  assert_success
  assert_output "running"
}

@test "domain_exists: nominal case" {
  # Mock the underlying tools
  virsh() {
    [[ "$*" == "dominfo foo" ]] && return 0
    return 1
  }
  export -f virsh

  # Run the test
  run in_bash domain_exists "foo"
  assert_success
  run in_bash domain_exists "bar"
  assert_failure
}

@test "get_zfs_datasets_from_domain: nominal case" {
  # Mock the underlying tools
  virsh() {
    if [[ "$*" == "domblklist foo --details" ]]; then
      cat <<-EOF
 Type   Device   Target   Source
------------------------------------------------------------------------
 file   disk     vda      /var/lib/libvirt/images/foo/root.img
 file   disk     vdb      /var/lib/libvirt/images/foo/data.img
 block  disk     vdc      /dev/zvol/data/domains/foo/data-vol
 block  disk     vdd      /dev/sda1
EOF
      return 0
    fi
    return 1
  }
  df() {
    if [[ "$*" == "--output=source /var/lib/libvirt/images/foo/root.img" ]] || [[ "$*" == "--output=source /var/lib/libvirt/images/foo/data.img" ]]; then
      echo Filesystem
      echo "/var/lib/libvirt/images/foo"
      return 0
    fi
    return 1
  }
  export -f virsh df

  # Run the test
  run in_bash get_zfs_datasets_from_domain "foo"
  assert_output "/var/lib/libvirt/images/foo"
  assert_success

  run in_bash get_zfs_datasets_from_domain "bar"
  assert_failure
}

@test "get_zfs_zvols_from_domain: nominal case" {
  # Mock the underlying tools
  virsh() {
    if [[ "$*" == "domblklist foo --details" ]]; then
      cat <<-EOF
 Type   Device   Target   Source
------------------------------------------------------------------------
 file   disk     vda      /var/lib/libvirt/images/foo/root.img
 file   disk     vdb      /var/lib/libvirt/images/foo/data.img
 block  disk     vdc      /dev/zvol/data/domains/foo/data-vol
 block  disk     vdd      /dev/sda1
EOF
      return 0
    fi
    return 1
  }
  export -f virsh

  # Run the test
  run in_bash get_zfs_zvols_from_domain "foo"
  assert_output "data/domains/foo/data-vol"
  assert_success

  run in_bash get_zfs_zvols_from_domain "bar"
  assert_failure
}

@test "get_zfs_snapshots_from_dataset: nominal case" {
  # Mock the underlying tools
  zfs() {
    if [[ "$*" == "list -H -t snapshot -o name data/domains/foo" ]]; then
      cat <<-EOF
data/domains/foo@snapshot1
data/domains/foo/virtiofs@snapshot1
data/domains/foo@snapshot2
data/domains/foo/virtiofs@snapshot2
EOF
      return 0
    fi
    return 1
  }
  export -f zfs

  # Run the test
  run in_bash get_zfs_snapshots_from_dataset "data/domains/foo"
  assert_output "snapshot1
snapshot2"
  assert_success

  run in_bash get_zfs_snapshots_from_dataset "data/domains/bar"
  assert_failure
}

@test "get_zfs_dataset_mountpoint: nominal case" {
  # Mock the underlying tools
  zfs() {
    if [[ "$*" == "get -H -o value mountpoint data/domains/foo" ]]; then
      echo "/var/lib/libvirt/images/foo"
      return 0
    fi
    return 1
  }
  export -f zfs

  # Run the test
  run in_bash get_zfs_dataset_mountpoint "data/domains/foo"
  assert_output "/var/lib/libvirt/images/foo"
  assert_success

  run in_bash get_zfs_dataset_mountpoint "data/domains/bar"
  assert_failure
}

@test "take_live_snapshot: nominal case" {
  # Mock the underlying tools
  declare -A domain_params_cache=( ["foo/state"]="running" ["foo/dataset"]="data/domains/foo" ["foo/mountpoint"]="/var/lib/libvirt/images/foo" ["foo/zvols"]="" )
  virsh_mock="$(mock_create)"
  virsh() {
    if [[ "$*" == "save foo /var/lib/libvirt/images/foo/domain.save --running --verbose --image-format raw" ]]; then
      $virsh_mock "$@"
      return $?
    fi
    return 1
  }
  zfs_mock="$(mock_create)"
  zfs() {
    if [[ "$*" == "snapshot -r data/domains/foo@backup1" ]]; then
      $zfs_mock "$@"
      return $?
    fi
    return 1
  }
  export -f virsh zfs
  export virsh_mock zfs_mock

  # Run the test
  run in_bash take_live_snapshot foo backup1
  assert_success
  [[ "$(mock_get_call_num ${virsh_mock})" -eq 1 ]]
  [[ "$(mock_get_call_num ${zfs_mock})" -eq 1 ]]
}

@test "take_crash_consistent_snapshot: nominal case" {
  # Mock the underlying tools
  declare -A domain_params_cache=( ["bar/state"]="running" ["bar/dataset"]="data/domains/bar" ["bar/mountpoint"]="/var/lib/libvirt/images/bar" ["bar/zvols"]="" )
  zfs_mock="$(mock_create)"
  zfs() {
    if [[ "$*" == "snapshot -r data/domains/bar@backup2" ]]; then
      $zfs_mock "$@"
      return $?
    fi
    return 1
  }
  export -f zfs
  export zfs_mock

  # Run the test
  run in_bash take_crash_consistent_snapshot bar backup2
  assert_success
  [[ "$(mock_get_call_num ${zfs_mock})" -eq 1 ]]
}

@test "revert_snapshot: nominal case" {
  # Mock the underlying tools
  verbose=1
  declare -A domain_params_cache=( ["baz/state"]="running" ["baz/dataset"]="data/domains/baz" ["baz/mountpoint"]="/var/lib/libvirt/images/baz" ["baz/zvols"]="" )
  zfs_mock="$(mock_create)"
  zfs() {
    rollback_pattern="^rollback -Rrf data/domains/baz(/virtiofs)?@backup3$"
    if [[ "$*" == "list -H -r -o name data/domains/baz" ]]; then
      echo "data/domains/baz
data/domains/baz/virtiofs"
      return 0
    elif [[ "$*" =~ $rollback_pattern ]]; then
      $zfs_mock "$@"
      return $?
    fi
    return 1
  }
  export -f zfs
  export zfs_mock

  # Run the test
  run in_bash revert_snapshot baz backup3
  assert_success
  [[ "$(mock_get_call_num ${zfs_mock})" -eq 2 ]]
}

@test "restore_domain: batch mode" {
  # Mock the underlying tools
  batch=1
  declare -A domain_params_cache=( ["foo/state"]="running" ["foo/dataset"]="data/domains/foo" ["foo/mountpoint"]="/var/lib/libvirt/images/foo" ["foo/zvols"]="" )
  virsh_mock="$(mock_create)"
  virsh() {
    if [[ "$*" == "restore /var/lib/libvirt/images/foo/domain.save --verbose --paused" ]]; then
      $virsh_mock "$@"
      return $?
    fi
    return 1
  }
  export -f virsh
  export virsh_mock

  # Run the test
  run in_bash restore_domain foo
  assert_success
  [[ "$(mock_get_call_num ${virsh_mock})" -eq 1 ]]
}

@test "restore_domain: nominal case" {
  # Mock the underlying tools
  batch=0
  declare -A domain_params_cache=( ["foo/state"]="running" ["foo/dataset"]="data/domains/foo" ["foo/mountpoint"]="/var/lib/libvirt/images/foo" ["foo/zvols"]="" )
  virsh_mock="$(mock_create)"
  virsh() {
    if [[ "$*" == "restore /var/lib/libvirt/images/foo/domain.save --verbose --running" ]]; then
      $virsh_mock "$@"
      return $?
    fi
    return 1
  }
  export -f virsh
  export virsh_mock

  # Run the test
  run in_bash restore_domain foo
  assert_success
  [[ "$(mock_get_call_num ${virsh_mock})" -eq 1 ]]
}

@test "pause_all_domains: nominal case" {
  # Mock the underlying tools
  local domains=( "foo" "bar" )
  declare -A domain_params_cache=( ["foo/state"]="running" ["bar/state"]="shut off" )
  virsh_mock="$(mock_create)"
  virsh() {
    if [[ "$*" == "suspend foo" ]]; then
      $virsh_mock "$@"
      return $?
    fi
    return 1
  }
  export -f virsh
  export virsh_mock

  # Run the test
  run in_bash pause_all_domains "${domains[@]}"
  assert_success
  [[ "$(mock_get_call_num ${virsh_mock})" -eq 1 ]]
}

@test "resume_all_domains: nominal case" {
  # Mock the underlying tools
  local domains=( "foo" "bar" )
  declare -A domain_params_cache=( ["foo/state"]="paused" ["bar/state"]="shut off" )
  virsh_mock="$(mock_create)"
  virsh() {
    if [[ "$*" == "resume foo" ]] || [[ "$*" == "start bar" ]]; then
      $virsh_mock "$@"
      return $?
    fi
    return 1
  }
  export -f virsh
  export virsh_mock

  # Run the test
  run in_bash resume_all_domains "${domains[@]}"
  assert_success
  [[ "$(mock_get_call_num ${virsh_mock})" -eq 2 ]]
}

@test "domain_checks: nominal case" {
  # Mock the underlying tools
  domain_exists() {
    if [[ "$*" == "foo" ]] || [[ "$*" == "bar" ]]; then
      return 0
    fi
    return 1
  }
  domain_state() {
    if [[ "$*" == "foo" ]]; then
      echo "running"
      return 0
    elif [[ "$*" == "bar" ]]; then
      echo "shut off"
      return 0
    fi
    return 1
  }
  get_zfs_datasets_from_domain() {
    if [[ "$*" == "foo" ]]; then
      echo "data/domains/foo"
      return 0
    elif [[ "$*" == "bar" ]]; then
      echo "data/domains/bar"
      return 0
    fi
    return 1
  }
  get_zfs_zvols_from_domain() {
    if [[ "$*" == "foo" ]]; then
      return 0
    elif [[ "$*" == "bar" ]]; then
      return 0
    fi
    return 1
  }
  get_zfs_snapshots_from_dataset() {
    if [[ "$*" == "data/domains/foo" ]]; then
      echo "backup1"
      return 0
    elif [[ "$*" == "data/domains/bar" ]]; then
      echo "backup1"
      return 0
    fi
    return 1
  }
  get_zfs_dataset_mountpoint() {
    if [[ "$*" == "data/domains/foo" ]]; then
      echo "/var/lib/libvirt/images/foo"
      return 0
    elif [[ "$*" == "data/domains/bar" ]]; then
      echo "/var/lib/libvirt/images/bar"
      return 0
    fi
    return 1
  }
  export -f domain_exists domain_state get_zfs_datasets_from_domain get_zfs_zvols_from_domain get_zfs_snapshots_from_dataset get_zfs_dataset_mountpoint

  # Run the test
  run in_bash domain_checks snapshot foo backup2
  assert_success
  run in_bash domain_checks revert bar backup1
  assert_success
}

@test "list_snapshots: nominal case" {
  # Mock the underlying tools
  get_zfs_datasets_from_domain() {
    if [[ "$*" == "foo" ]]; then
      echo "data/domains/foo"
      return 0
    fi
    return 1
  }
  get_zfs_snapshots_from_dataset() {
    if [[ "$*" == "data/domains/foo" ]]; then
      echo "snapshot1
snapshot2"
      return 0
    fi
    return 1
  }
  export -f get_zfs_datasets_from_domain get_zfs_snapshots_from_dataset

  # Run the test
  run in_bash list_snapshots foo
  assert_success
  assert_output "Snapshots for domain 'foo':
  - snapshot1
  - snapshot2"
}

@test "preflight_checks: nominal case" {
  # Mock the underlying tools
  domain_checks() {
    if [[ "$*" == "snapshot foo backup2" ]]; then
      return 0
    fi
    return 1
  }
  export -f domain_checks

  # Run the test
  run in_bash preflight_checks snapshot backup2 foo
  assert_success
}

@test "take_snapshots: batch=0, live=0" {
  # Mock the underlying tools
  take_crash_consistent_snapshot() {
    regex="^(foo|bar) backup$"
    if [[ "$*" =~ $regex ]]; then
      return 0
    fi
    return 1
  }
  pause_all_domains() { return 1; }
  take_live_snapshot() { return 1; }
  restore_domain() { return 1; }
  resume_all_domains() { return 1; }
  export -f take_crash_consistent_snapshot pause_all_domains take_live_snapshot restore_domain resume_all_domains

  declare -A domain_params_cache=( ["foo/state"]="running" ["bar/state"]="shut off" )

  # Run the test
  domains=( "foo" "bar" )
  snapshot_name="backup"
  batch=0
  live=0
  run in_bash take_snapshots
  assert_success

  # Add a non-existing domain to the list
  domains+=( "baz" )
  run in_bash take_snapshots
  assert_failure
}

@test "take_snapshots: batch=1, live=0" {
  # Mock the underlying tools
  take_crash_consistent_snapshot() {
    regex="^(foo|bar) backup$"
    if [[ "$*" =~ $regex ]]; then
      return 0
    fi
    return 1
  }
  pause_all_domains() {
    if [[ "$*" == "foo bar" ]]; then
      return 0
    fi
    return 1
  }
  take_live_snapshot() { return 1; }
  restore_domain() { return 1; }
  resume_all_domains() {
    if [[ "$*" == "foo bar" ]]; then
      return 0
    fi
    return 1

  }
  export -f take_crash_consistent_snapshot pause_all_domains take_live_snapshot restore_domain resume_all_domains

  declare -A domain_params_cache=( ["foo/state"]="running" ["bar/state"]="shut off" )

  # Run the test
  domains=( "foo" "bar" )
  snapshot_name="backup"
  batch=1
  live=0
  run in_bash take_snapshots
  assert_success

  # Add a non-existing domain to the list
  domains+=( "baz" )
  run in_bash take_snapshots
  assert_failure
}

@test "take_snapshots: batch=0, live=1" {
  # Mock the underlying tools
  take_crash_consistent_snapshot() {
    if [[ "$*" == "bar backup" ]]; then
      return 0
    fi
    return 1
  }
  pause_all_domains() { return 1; }
  take_live_snapshot() {
    if [[ "$*" == "foo backup" ]]; then
      return 0
    fi
    return 1
 }
  restore_domain() {
    if [[ "$*" == "foo" ]]; then
      return 0
    fi
    return 1
  }
  resume_all_domains() { return 1; }
  export -f take_crash_consistent_snapshot pause_all_domains take_live_snapshot restore_domain resume_all_domains

  declare -A domain_params_cache=( ["foo/state"]="running" ["bar/state"]="shut off" )

  # Run the test
  domains=( "foo" "bar" )
  snapshot_name="backup"
  batch=0
  live=1
  run in_bash take_snapshots
  assert_success

  # Add a non-existing domain to the list
  domains+=( "baz" )
  run in_bash take_snapshots
  assert_failure
}

@test "revert_snapshots: batch=0" {
  # Mock the underlying tools
  revert_snapshot() {
    regex="^(foo|bar) backup$"
    if [[ "$*" =~ $regex ]]; then
      return 0
    fi
    return 1
  }
  restore_domain() {
    regex="^(foo|bar)$"
    if [[ "$*" =~ $regex ]]; then
      return 0
    fi
    return 1
  }
  resume_all_domains() { return 1; }
  export -f revert_snapshot restore_domain resume_all_domains

  # Run the test
  domains=( "foo" "bar" )
  snapshot_name="backup"
  batch=0
  run in_bash revert_snapshots
  assert_success

  # Add a non-existing domain to the list
  domains+=( "baz" )
  run in_bash revert_snapshots
  assert_failure
}

@test "revert_snapshots: batch=1" {
  # Mock the underlying tools
  revert_snapshot() {
    regex="^(foo|bar) backup$"
    if [[ "$*" =~ $regex ]]; then
      return 0
    fi
    return 1
  }
  restore_domain() {
    regex="^(foo|bar)$"
    if [[ "$*" =~ $regex ]]; then
      return 0
    fi
    return 1
  }
  resume_all_domains() {
    if [[ "$*" == "foo bar" ]]; then
      return 0
    fi
    return 1
  }
  export -f revert_snapshot restore_domain resume_all_domains

  # Run the test
  domains=( "foo" "bar" )
  snapshot_name="backup"
  batch=1
  run in_bash revert_snapshots
  assert_success

  # Add a non-existing domain to the list
  domains+=( "baz" )
  run in_bash revert_snapshots
  assert_failure
}

