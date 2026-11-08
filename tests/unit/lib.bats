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

@test "step accepts a service id NN-id and writes its marker" {
  run in_lib 'f() { :; }; step 30-postgres-exporter f'
  [ "$status" -eq 0 ]
  [ -e "$HOMELAB_STATE_DIR/done/30-postgres-exporter" ]
}

@test "step rejects an id that is not NN or NN-id" {
  local id
  for id in 5 30_db 30-DB 30- 30-a/b; do
    run in_lib "f() { :; }; step '$id' f"
    [ "$status" -eq 1 ]
    [[ $output == *"must be NN or NN-id"* ]]
  done
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
  run in_lib "load_env '$BATS_TEST_TMPDIR/node.env' GREETING GREETING; bash -c 'echo \"\$GREETING\"'"
  [ "$output" = "hi there" ]
}

@test "load_env fails for a missing file" {
  run in_lib "load_env '$BATS_TEST_TMPDIR/nope.env' A"
  [ "$status" -eq 1 ]
  [[ $output == *"not readable"* ]]
}

@test "load_env fails when a required variable is missing" {
  printf 'A=1\n' >"$BATS_TEST_TMPDIR/node.env"
  run in_lib "load_env '$BATS_TEST_TMPDIR/node.env' 'A|B' A B"
  [ "$status" -eq 1 ]
  [[ $output == *"required variable B"* ]]
}

@test "load_env warns when a secrets file is readable by others" {
  printf 'X=1\n' >"$BATS_TEST_TMPDIR/secrets.env"
  chmod 644 "$BATS_TEST_TMPDIR/secrets.env"
  run in_lib "load_env '$BATS_TEST_TMPDIR/secrets.env' X"
  [ "$status" -eq 0 ]
  [[ $output == *"mode 644, expected 600"* ]]
}

@test "load_env does not warn for a secrets file with mode 600" {
  printf 'X=1\n' >"$BATS_TEST_TMPDIR/secrets.env"
  chmod 600 "$BATS_TEST_TMPDIR/secrets.env"
  run in_lib "load_env '$BATS_TEST_TMPDIR/secrets.env' X"
  [ -z "$output" ]
}

@test "write_file writes stdin atomically with the given mode" {
  run in_lib "printf 'a\nb\n' | write_file '$BATS_TEST_TMPDIR/d/f' 640"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/d/f")" = $'a\nb' ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/d/f")" = 640 ]
  [ -z "$(find "$BATS_TEST_TMPDIR/d" -name 'f.*')" ]
}

@test "write_file in dry-run prints path and content, hides mode-600 content, writes nothing" {
  run in_lib "DRY_RUN=1; echo 'Port 2222' | write_file '$BATS_TEST_TMPDIR/x.conf'; echo secret | write_file '$BATS_TEST_TMPDIR/k' 600"
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] write $BATS_TEST_TMPDIR/x.conf (mode 644)"*"[dry-run]   Port 2222"* ]]
  [[ $output == *"(content hidden)"* && $output != *secret* ]]
  [ ! -e "$BATS_TEST_TMPDIR/x.conf" ]
}

@test "load_node_env needs HOMELAB_NODE_DIR and valid ports" {
  run in_lib 'unset HOMELAB_NODE_DIR; load_node_env'
  [ "$status" -eq 1 ]
  [[ $output == *"HOMELAB_NODE_DIR is not set"* ]]
  mkdir -p "$BATS_TEST_TMPDIR/n"
  printf 'NODE_NAME=a\nWG_IP=10.100.10.101\nWG_PORT=70000\nSSH_PORT=22\nRUNTIME=compose\nOS=debian\n' >"$BATS_TEST_TMPDIR/n/node.env"
  run in_lib "HOMELAB_NODE_DIR='$BATS_TEST_TMPDIR/n'; load_node_env"
  [ "$status" -eq 1 ]
  [[ $output == *"WG_PORT must be a port 1-65535, got: 70000"* ]]
}

@test "load_env never executes the file: command substitution, backticks and ; are rejected" {
  local f="$BATS_TEST_TMPDIR/evil.env"
  for line in 'A=$(touch PWNED)' 'A="`touch PWNED`"' 'A=1; touch PWNED' 'A=1 touch PWNED' 'touch PWNED'; do
    printf '%s\n' "$line" >"$f"
    run in_lib "cd '$BATS_TEST_TMPDIR'; load_env '$f' A"
    [ "$status" -eq 1 ]
    [[ $output == *"evil.env:1: expected KEY=value"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/PWNED" ]
  done
}

@test "load_env rejects keys outside the allow list (PATH, LD_PRELOAD) and duplicates" {
  printf 'A=1\nPATH=/tmp/evil\nLD_PRELOAD=/tmp/x.so\nA=2\n' >"$BATS_TEST_TMPDIR/e.env"
  run in_lib "load_env '$BATS_TEST_TMPDIR/e.env' A"
  [ "$status" -eq 1 ]
  [[ $output == *"key PATH is not allowed"* && $output == *"key LD_PRELOAD is not allowed"* ]]
  [[ $output == *"duplicate key A"* ]]
}

@test "parse_common_args rejects positional arguments and non-boolean DRY_RUN/FORCE" {
  run in_lib 'parse_common_args --dry-run extra'
  [ "$status" -eq 1 ]
  [[ $output == *"unknown argument: extra"* ]]
  run in_lib 'DRY_RUN="1; id"; parse_common_args'
  [ "$status" -eq 1 ]
  [[ $output == *"DRY_RUN and FORCE must be 0 or 1"* ]]
}

@test "ssh_session accepts only client_ip client_port server_ip server_port" {
  run in_lib 'SSH_CONNECTION="10.100.10.200 5000 10.100.10.101 2222"; ssh_session; echo "$SSH_CLIENT_IP $SSH_SERVER_PORT"'
  [ "$output" = "10.100.10.200 2222" ]
  run in_lib 'SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22;id"; ssh_session; echo "[$SSH_CLIENT_IP][$SSH_SERVER_PORT]"'
  [[ $output == *"ignoring malformed SSH_CONNECTION"*"[][]"* ]]
  run in_lib 'SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22 extra"; ssh_session; echo "[$SSH_SERVER_PORT]"'
  [[ $output == *"[]"* ]]
}

@test "os_release_value reads plain values only and never executes the file" {
  printf 'ID="debian"\nVERSION_CODENAME=trixie\nNAME=$(touch %s/PWNED)\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/os"
  run in_lib "HOMELAB_OS_RELEASE='$BATS_TEST_TMPDIR/os'; os_release_value ID; os_release_value VERSION_CODENAME; echo \"[\$(os_release_value NAME)]\""
  [ "$output" = $'debian\ntrixie\n[]' ]
  [ ! -e "$BATS_TEST_TMPDIR/PWNED" ]
}

@test "fetch allows https only and passes the URL as one argument" {
  run in_lib "DRY_RUN=1; fetch 'https://example.com/a b' /tmp/x"
  [ "$status" -eq 0 ]
  [[ $output == *"--proto =https"*"https://example.com/a\ b"* ]]
  run in_lib "DRY_RUN=1; fetch 'http://example.com' /tmp/x"
  [ "$status" -eq 1 ]
  [[ $output == *"only https URLs"* ]]
}

@test "verify_sha256 accepts the right checksum and dies on any other" {
  echo data >"$BATS_TEST_TMPDIR/f"
  local sum
  sum=$(sha256sum "$BATS_TEST_TMPDIR/f" | cut -d' ' -f1)
  run in_lib "verify_sha256 '$BATS_TEST_TMPDIR/f' $sum"
  [ "$status" -eq 0 ]
  run in_lib "verify_sha256 '$BATS_TEST_TMPDIR/f' 0000"
  [ "$status" -eq 1 ]
  [[ $output == *"checksum mismatch"* ]]
}
