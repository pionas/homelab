#!/usr/bin/env bats
# Tests for common/lib.sh.
# shellcheck disable=SC2016,SC2154 # scripts expand in the child bash; $stderr is set by bats

setup() {
  load helpers
  export HOMELAB_STATE_DIR="$BATS_TEST_TMPDIR/state"
  MARKER="$HOMELAB_STATE_DIR/done/05"
}

@test "run executes the command outside dry-run" {
  in_lib "run touch '$BATS_TEST_TMPDIR/file'"
  [ -e "$BATS_TEST_TMPDIR/file" ]
}

@test "run in dry-run prints the quoted command and does not execute it" {
  local target="$BATS_TEST_TMPDIR/a b"
  run in_lib "DRY_RUN=1; run touch '$target'"
  [ "$status" -eq 0 ]
  [ "$output" = "[dry-run] touch $(printf %q "$target")" ]
  [ ! -e "$target" ]
}

@test "step runs the function and writes its marker" {
  run in_lib 'f() { echo ran; }; step 05 f'
  [ "$status" -eq 0 ]
  [[ $output == *ran* ]]
  [ -e "$MARKER" ]
}

@test "step skips a step that is already done" {
  mkdir -p "${MARKER%/*}" && touch "$MARKER"
  run in_lib 'f() { echo ran; }; step 05 f'
  [ "$status" -eq 0 ]
  [[ $output != *ran* ]]
  [[ $output == *"already done"* ]]
}

@test "step reruns a done step with --force" {
  mkdir -p "${MARKER%/*}" && touch "$MARKER"
  run in_lib 'parse_common_args --force; f() { echo ran; }; step 05 f'
  [[ $output == *ran* ]]
}

@test "step in dry-run runs the function but writes no marker" {
  run in_lib 'DRY_RUN=1; f() { echo ran; }; step 05 f'
  [[ $output == *ran* ]]
  [ ! -e "$MARKER" ]
}

@test "step writes no marker when the function fails" {
  run in_lib 'f() { return 3; }; step 05 f'
  [ "$status" -ne 0 ]
  [ ! -e "$MARKER" ]
}

@test "step rejects an id that is not two digits" {
  run in_lib 'f() { :; }; step 5 f'
  [ "$status" -eq 1 ]
  [[ $output == *"two digits"* ]]
}

@test "logs go to stderr, not stdout" {
  run --separate-stderr in_lib 'log_info hello'
  [ -z "$output" ]
  [[ $stderr == *"[INFO] hello"* ]]
}

@test "LOG_LEVEL=warn hides info and shows warn" {
  run in_lib 'LOG_LEVEL=warn; log_info quiet; log_warn loud'
  [[ $output != *quiet* ]]
  [[ $output == *"[WARN] loud"* ]]
}

@test "LOG_LEVEL=debug shows debug messages" {
  run in_lib 'LOG_LEVEL=debug; log_debug details'
  [[ $output == *"[DEBUG] details"* ]]
}

@test "logs have no color codes when stderr is not a TTY" {
  run in_lib 'log_error plain'
  [[ $output != *$'\e'* ]]
}

@test "parse_common_args sets dry-run and force" {
  run in_lib 'parse_common_args --dry-run --force; echo "$DRY_RUN $FORCE"'
  [ "$output" = "1 1" ]
}

@test "parse_common_args rejects an unknown argument" {
  run in_lib 'parse_common_args --yes'
  [ "$status" -eq 1 ]
  [[ $output == *"unknown argument: --yes"* ]]
}

@test "require_root fails for a regular user" {
  ((EUID != 0)) || skip "running as root"
  run in_lib 'require_root'
  [ "$status" -eq 1 ]
  [[ $output == *"must be run as root"* ]]
}

@test "require_root only warns for a regular user in dry-run" {
  ((EUID != 0)) || skip "running as root"
  run in_lib 'DRY_RUN=1; require_root; echo continued'
  [ "$status" -eq 0 ]
  [[ $output == *"[WARN]"* && $output == *continued* ]]
}

@test "load_env exports variables to child processes" {
  printf 'GREETING="hi there"\n' >"$BATS_TEST_TMPDIR/node.env"
  run in_lib "load_env '$BATS_TEST_TMPDIR/node.env' GREETING; bash -c 'echo \"\$GREETING\"'"
  [ "$output" = "hi there" ]
}

@test "load_env fails for a missing file" {
  run in_lib "load_env '$BATS_TEST_TMPDIR/nope.env'"
  [ "$status" -eq 1 ]
  [[ $output == *"not readable"* ]]
}

@test "load_env fails when a required variable is missing" {
  printf 'A=1\n' >"$BATS_TEST_TMPDIR/node.env"
  run in_lib "load_env '$BATS_TEST_TMPDIR/node.env' A B"
  [ "$status" -eq 1 ]
  [[ $output == *"required variable B"* ]]
}

@test "load_env warns when a secrets file is readable by others" {
  printf 'X=1\n' >"$BATS_TEST_TMPDIR/secrets.env"
  chmod 644 "$BATS_TEST_TMPDIR/secrets.env"
  run in_lib "load_env '$BATS_TEST_TMPDIR/secrets.env'"
  [ "$status" -eq 0 ]
  [[ $output == *"mode 644, expected 600"* ]]
}

@test "load_env does not warn for a secrets file with mode 600" {
  printf 'X=1\n' >"$BATS_TEST_TMPDIR/secrets.env"
  chmod 600 "$BATS_TEST_TMPDIR/secrets.env"
  run in_lib "load_env '$BATS_TEST_TMPDIR/secrets.env'"
  [ -z "$output" ]
}
