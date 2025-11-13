#!/usr/bin/env bats

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  source "${BATS_TEST_DIRNAME}/../../src/lib/core.sh"

  virsh() {
    [[ "$1" == "domstate" && "$2" == "foo" ]] && echo "running"
  }
  export -f virsh
}

@test "domain_state retourne 'running' pour le domaine foo" {
  run domain_state "foo"
  assert_success
  assert_output "running"
}
