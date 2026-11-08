# shellcheck shell=bash
# Shared helpers for unit tests.

bats_require_minimum_version 1.5.0

REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
export REPO_ROOT

# common/lib.sh defines `run`, which would shadow bats' own `run`,
# so library code always executes in a child bash with production shell options.
in_lib() {
  bash -c 'set -Eeuo pipefail; source "$REPO_ROOT/common/lib.sh"; '"$1"
}

in_catalog() {
  bash -c 'set -Eeuo pipefail; source "$REPO_ROOT/lib/catalog.sh"; '"$1"
}

# Copies the valid fixture catalog to $CAT so a test can break one thing in it.
copy_catalog() {
  CAT="$BATS_TEST_TMPDIR/catalog"
  cp -r "$REPO_ROOT/tests/fixtures/catalog-valid" "$CAT"
}

# set_key SERVICE KEY RAW_VALUE — replaces the KEY line in the copied catalog.
set_key() {
  sed -i "s|^$2=.*|$2=$3|" "$CAT/$1/service.conf"
}

# expect_invalid MESSAGE [DIR] — catalog_load on DIR (default $CAT) fails and logs MESSAGE.
expect_invalid() {
  run in_catalog "catalog_load '${2:-$CAT}'"
  [ "$status" -eq 1 ]
  [[ $output == *"$1"* ]]
}
