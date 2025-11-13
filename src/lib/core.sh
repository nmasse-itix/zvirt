# Reports a verbose message to stdout if verbose mode is enabled.
function log_verbose () {
  if [ "$verbose" -eq 1 ]; then
    echo "$@" 2>&1
  fi
}

# Reports a fatal error message to stderr and exits with a non-zero exit code.
function fatal () {
    echo "Error: $@" 2>&1
    exit 1
}

# Reports an error message to stderr.
function error () {
    echo "Error: $@" 2>&1
}

function show_help () {
  cat << EOF
Usage: ${0##*/} action [-h] [-l] [-v] -d <domain_name> -s <snapshot_name>

Options:
  -h          display this help and exit
  -v          verbose mode
  -l          live snapshot mode (default is crash-consistent)
  -d DOMAIN   specify domain name (you can specify multiple -d options)
  -s SNAPSHOT specify snapshot name
  -b          batch mode (pause all domains, take snapshots, then resume all domains)

Actions:
  snapshot    take a snapshot of the specified domain(s)
  revert      revert to a snapshot of the specified domain(s)
  list        list snapshots of the specified domain(s) (or all domains if none specified)

Examples:
  Take a crash-consistent snapshot of domain 'vm1' named 'backup1':
    ${0##*/} snapshot -d vm1 -s backup1

  Take a live snapshot of domains 'vm1' and 'vm2' in batch mode, named 'livebackup':
    ${0##*/} snapshot -l -b -d vm1 -d vm2 -s livebackup

  Revert domain 'vm1' to snapshot 'backup1':
    ${0##*/} revert -d vm1 -s backup1

  List snapshots of domain 'vm1':
    ${0##*/} list -d vm1

  List snapshots of all domains:
    ${0##*/} list
EOF
}


# Initialize the global variables
function init_global_variables () {
  # Command line parsing variables
  snapshot_name=""
  domains=()
  verbose=0
  action=""
  batch=0
  live=0
  should_exit=0

  # Cache for domain parameters to avoid redundant calls to the zfs command
  declare -A domain_params_cache=( )
}

# Parses the command-line arguments.
function parse_args () {
  # Try to get the action from the first positional argument
  if [ -n "${1:-}" ] && [[ ! "${1:-}" =~ ^- ]]; then
    action="${1:-}"
    shift || true
  fi

  OPTIND=1 # Reset in case getopts has been used previously in the shell.

  while getopts "h?blvd:s:" opt; do
    case "$opt" in
      h|\?)
        show_help
        exit 0
        ;;
      v)  verbose=1
        ;;
      d)  domains+=( "$OPTARG" )
        ;;
      s)  snapshot_name="$OPTARG"
        ;;
      b)  batch=1
        ;;
      l)  live=1
        ;;
      *)  show_help >&2
        exit 1
        ;;
    esac
  done

  shift $((OPTIND-1))

  [ "${1:-}" = "--" ] && shift

  if [ $# -ne 0 ]; then
    echo "Error: Unexpected positional arguments: $*"
    should_exit=1
  fi

  case "$action" in
    snapshot)
      if [ ${#domains[@]} -eq 0 ] || [ -z "$snapshot_name" ]; then
        echo "Error: Domain name(s) and snapshot name must be specified."
        should_exit=1
      fi

      if [ "$batch" -eq 1 ] && [ "$live" -ne 1 ]; then
        echo "Error: Batch mode requires live snapshot mode."
        should_exit=1
      fi

      if [[ ! "$snapshot_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "Error: Snapshot name '$snapshot_name' contains invalid characters. Only alphanumeric characters, dots (.), underscores (_) and hyphens (-) are allowed."
        should_exit=1
      fi
      ;;
    revert)
      if [ ${#domains[@]} -eq 0 ] || [ -z "$snapshot_name" ]; then
        echo "Error: Domain name(s) and snapshot name must be specified."
        should_exit=1
      fi

      if [ "$live" -eq 1 ]; then
        echo "Error: Live mode is only supported for the 'snapshot' action."
        should_exit=1
      fi
      ;;
    list)
      ;;
    *) 
      echo "Error: Unsupported action '$action'."
      should_exit=1
      ;;
  esac

  return $should_exit
}

# Checks if the specified domain exists.
function domain_exists () {
  local domain="$1"
  if virsh dominfo "$domain" &> /dev/null; then
    return 0
  else
    return 1
  fi
}

# Performs various checks on the specified domain before taking or reverting a snapshot.
# All the checks are performed according to the specified action (snapshot or revert).
# Any errors are reported via stderr and the function returns a non-zero exit code.
function domain_checks () {
  local action="$1"
  local domain="$2"
  local snapshot_name="$3"
  local error=0
  local state=""

  if ! domain_exists "$domain"; then
    error "Domain '$domain' does not exist."
    return 1 # There is no point in continuing checks if the domain does not exist
  fi

  # ZFS dataset checks
  zfs_datasets=( $(get_zfs_datasets_from_domain "$domain") )
  if [ ${#zfs_datasets[@]} -ne 1 ]; then
    error "$domain: Wrong number of ZFS datasets (${#zfs_datasets[@]}) found." ; error=1
  fi
  zfs_dataset="${zfs_datasets[0]:-}"

  # Zvols checks
  zfs_zvols=( $(get_zfs_zvols_from_domain "$domain") )
  for zvol in "${zfs_zvols[@]}"; do
    # Check if zvol is a child of $zfs_dataset
    if [[ "$zvol" != "$zfs_dataset"* ]]; then
      error "$domain: ZFS zvol '$zvol' is not a child of dataset '$zfs_dataset'." ; error=1
    fi
  done

  zfs_dataset_snapshots=( $(get_zfs_snapshots_from_dataset "${zfs_dataset}") )
  zfs_mountpoint=$(zfs get -H -o value mountpoint "${zfs_dataset}")

  if [ -z "$zfs_mountpoint" ] || [[ ! "$zfs_mountpoint" =~ ^/ ]]; then
    error "$domain: Wrong ZFS mountpoint for dataset '$zfs_dataset': '$zfs_mountpoint'." ; error=1
  elif [ ! -d "$zfs_mountpoint" ]; then
    error "$domain: ZFS mountpoint '$zfs_mountpoint' does not exist." ; error=1
  fi

  state=$(domain_state "$domain")

  case "$action" in
    snapshot)
      # Check domain state
      if [ "$state" != "shut off" ] && [ "$state" != "running" ]; then
        error "$domain: Domain must be either 'shut off' or 'running' to take a snapshot (current state: '$state')." ; error=1
      fi

      # Check if live snapshot requested on powered-off domain
      if [ "$live" -eq 1 ] && [ "$state" != "running" ]; then
        log_verbose "$domain: Live snapshot requested but domain is not running."
      fi

      # Check if snapshot already exists
      if printf '%s\n' "${zfs_dataset_snapshots[@]}" | grep -Fqx "$snapshot_name" ; then
        error "$domain: Snapshot '$snapshot_name' already exists." ; error=1
      fi
      for zvol in "${zfs_zvols[@]}"; do
        zfs_zvol_snapshots=( $(get_zfs_snapshots_from_dataset "$zvol") )
        if printf '%s\n' "${zfs_zvol_snapshots[@]}" | grep -Fqx "$snapshot_name" ; then
          error "$domain: Snapshot '$snapshot_name' already exists for ZFS zvol '$zvol'." ; error=1
        fi
      done

      # Check if save file already exists for live snapshot
      if [ -f "${zfs_mountpoint}/domain.save" ]; then
        error "$domain: Save file '${zfs_mountpoint}/domain.save' already exists." ; error=1
      fi
    ;;
    revert)
      # Check domain state
      if [ "$state" != "shut off" ]; then
        error "$domain: Domain must be 'shut off' to revert a snapshot (current state: '$state')." ; error=1
      fi

      # Check if snapshot exists
      if ! printf '%s\n' "${zfs_dataset_snapshots[@]}" | grep -Fqx "$snapshot_name" ; then
        error "$domain: Snapshot '$snapshot_name' does not exist for domain '$domain'." ; error=1
      fi
      for zvol in "${zfs_zvols[@]}"; do
        zfs_zvol_snapshots=( $(get_zfs_snapshots_from_dataset "$zvol") )
        if ! printf '%s\n' "${zfs_zvol_snapshots[@]}" | grep -Fqx "$snapshot_name" ; then
          error "$domain: Snapshot '$snapshot_name' does not exist for ZFS zvol '$zvol'." ; error=1
        fi
      done
      ;;
    *)
      error "$domain: Unknown action '$action'."
      ;;
  esac

  if [ $error -ne 0 ]; then
    error "$domain: Domain checks failed."
    return 1
  fi

  # Store those values in cache for later use
  domain_params_cache["$domain"]=( "${state}" "${zfs_dataset}" "$zfs_mountpoint" "${zfs_zvols[*]}" )

  return 0
}

# Gets the current state of the specified domain.
function domain_state () {
  local domain="$1"
  virsh domstate "$domain"
}

# Gets the list of ZFS datasets used by the specified domain (excluding zvols)
function get_zfs_datasets_from_domain () {
  local domain="$1"
  virsh domblklist "$domain" --details | awk '$1 == "file" && $2 == "disk" { print $4 }' | while read -r file; do df --output=source "$file" | tail -n 1; done | sort | uniq
}

# Gets the list of ZFS zvols used by the specified domain
function get_zfs_zvols_from_domain () {
  local domain="$1"
  virsh domblklist "$domain" --details | awk '$1 == "block" && $2 == "disk" && $4 ~ /^\/dev\/zvol\// { print gsub(/\/dev\/zvol\//, "", $4) }'
}

# Gets the list of ZFS snapshots for the specified dataset.
function get_zfs_snapshots_from_dataset () {
  local dataset="$1"
  zfs list -H -t snapshot -o name "$dataset" | awk -F'@' '{print $2}'
}

# Takes a live snapshot of the specified domain.
function take_live_snapshot () {
  local domain="$1"
  local snapshot="$2"

  log_verbose "$domain: Taking live snapshot '$snapshot'..."
  zfs_dataset="${domain_params_cache["$domain"][1]}"
  zfs_mountpoint="${domain_params_cache["$domain"][2]}"
  virsh save "$domain" "${zfs_mountpoint}/domain.save" --running --verbose --image-format raw
  zfs snapshot -r "${zfs_dataset}@${snapshot}"
}

# Takes a crash-consistent snapshot of the specified domain.
function take_crash_consistent_snapshot () {
  local domain="$1"
  local snapshot="$2"

  log_verbose "$domain: Taking crash-consistent snapshot '$snapshot'..."
  zfs_dataset="${domain_params_cache["$domain"][1]}"
  zfs_mountpoint="${domain_params_cache["$domain"][2]}"
  zfs snapshot -r "${zfs_dataset}@${snapshot}"
}

# Reverts the specified snapshot for the given domain.
function revert_snapshot () {
  local domain="$1"
  local snapshot="$2"

  log_verbose "$domain: Reverting snapshot '$snapshot'..."
  zfs_dataset="${domain_params_cache["$domain"][1]}"
  zfs_mountpoint="${domain_params_cache["$domain"][2]}"
  zfs list -H -r -o name "$zfs_dataset" | while read dataset; do 
    zfs rollback -Rrf "$dataset@$snapshot"
  done
}

# Restores a saved domain.
function restore_domain () {
  local domain="$1"
  
  log_verbose "$domain: Restoring live snapshot..."
  zfs_dataset="${domain_params_cache["$domain"][1]}"
  zfs_mountpoint="${domain_params_cache["$domain"][2]}"
  virsh_restore_opts=( )
  if [ "$batch" -eq 1 ]; then
    virsh_restore_opts+=( "--paused" )
  else
    virsh_restore_opts+=( "--running" )
  fi
  virsh restore "${zfs_mountpoint}/domain.save" --verbose "${virsh_restore_opts[@]}"
}

# Pauses all domains in the list.
function pause_all_domains () {
  for domain in "${domains[@]}"; do
    log_verbose "$domain: Pausing domain..."
    state="${domain_params_cache["$domain"][0]}"
    if [ "$state" == "running" ]; then
      virsh suspend "$domain"
    fi
  done
}

# Resumes all domains in the list.
function resume_all_domains () {
  for domain in "${domains[@]}"; do
    log_verbose "$domain: Resuming domain..."
    state="${domain_params_cache["$domain"][0]}"
    case "$(domain_state "$domain")" in
      paused)
        virsh resume "$domain" || true
        ;;
      "shut off")
        virsh start "$domain" || true
        ;;
      *)
        continue
        ;;
    esac
  done
}

# Performs pre-flight checks for all specified domains according to the action.
function preflight_checks () {
  local action="$1"
  local error=0

  for domain in "${domains[@]}"; do
    log_verbose "$domain: Performing domain pre-flight checks for $action..."
    if ! domain_checks "$action" "$domain" "$snapshot_name"; then
      error=1
    fi
  done

  return $error
}

# Takes snapshots for all specified domains.
function take_snapshots () {
  if [ "$batch" -eq 1 ]; then
    pause_all_domains
  fi

  for domain in "${domains[@]}"; do
    state="${domain_params_cache["$domain"][0]}"
    if [ "$live" -eq 1 ]; then
      take_live_snapshot "$domain" "$snapshot_name"
      restore_domain "$domain"
    else
      take_crash_consistent_snapshot "$domain" "$snapshot_name"
    fi
  done

  if [ "$batch" -eq 1 ]; then
    resume_all_domains
  fi

  return $error
}

# Reverts snapshots for all specified domains.
function revert_snapshots () {
  for domain in "${domains[@]}"; do
    revert_snapshot "$domain" "$snapshot_name"
    restore_domain "$domain"
  done

  if [ "$batch" -eq 1 ]; then
    resume_all_domains
  fi
}

# Lists snapshots for all specified domains.
function list_snapshots () {
  local domains=( "$@" )
  local zfs_dataset=""
  local zfs_mountpoint=""

  # TODO
  #for domain in "${domains[@]}"; do

  zfs_datasets=( $(get_zfs_datasets_from_domain "$domain") )
  if [ ${#zfs_datasets[@]} -ne 1 ]; then
    error "$domain: Wrong number of ZFS datasets (${#zfs_datasets[@]}) found." ; return 1
  fi
  zfs_dataset="${zfs_datasets[0]:-}"
  zfs_mountpoint=$(zfs get -H -o value mountpoint "${zfs_dataset}")

  echo "Snapshots for domain '$domain':"
  zfs list -H -t snapshot -o name "$zfs_dataset" | awk -F'@' '{print $2}'
}
