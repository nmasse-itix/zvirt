#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  bats_load_library 'bats-support'
  bats_load_library 'bats-assert'

  set -Eeuo pipefail
  source "${BATS_TEST_DIRNAME}/../../src/lib/core.sh"

  function call_parse_args () {
    init_global_variables
    parse_args "$@"
    ret=$?
    declare -p action batch live verbose domains snapshot_name
    return $ret
  }
}

@test "call_parse_args: show help and exit" {
  run call_parse_args -h
  assert_success
  assert_output --partial "Usage:"
}

@test "call_parse_args: no action provided" {
  run call_parse_args
  assert_failure
  assert_output --partial "Unsupported action"
}

@test "call_parse_args: list snapshots for a single domain" {
  run call_parse_args list -d foo
  assert_success
  assert_output --partial 'action="list"'
  assert_output --partial 'domains=([0]="foo")'
}

@test "call_parse_args: take a snapshot for two domains in batch mode" {
  run call_parse_args snapshot -b -d foo -d bar -s backup1 -l
  assert_success
  assert_output --partial 'action="snapshot"'
  assert_output --partial 'batch="1"'
  assert_output --partial 'domains=([0]="foo" [1]="bar")'
  assert_output --partial 'snapshot_name="backup1"'
  assert_output --partial 'live="1"'
}

@test "call_parse_args: take a crash-consistent snapshot for two domains" {
  run call_parse_args snapshot -d foo -d bar -s backup2
  assert_success
  assert_output --partial 'action="snapshot"'
  assert_output --partial 'batch="0"'
  assert_output --partial 'domains=([0]="foo" [1]="bar")'
  assert_output --partial 'snapshot_name="backup2"'
  assert_output --partial 'live="0"'
}

@test "call_parse_args: revert snapshot for a domain" {
  run call_parse_args revert -d foo -s backup2
  assert_success
  assert_output --partial 'action="revert"'
  assert_output --partial 'batch="0"'
  assert_output --partial 'domains=([0]="foo")'
  assert_output --partial 'snapshot_name="backup2"'
  assert_output --partial 'live="0"'
}

