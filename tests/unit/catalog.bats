#!/usr/bin/env bats
# Tests for lib/catalog.sh. Fixture: tests/fixtures/catalog-valid
#   node-agent  always compose,k3s 12
#   db          single compose 30  AUTO_ADD=db-exporter SECRETS="ROOT DEFAULT VIEWER"
#   db-exporter auto   compose 39  REQUIRES=db AUTO_ADD=log-shipper USES_SECRETS=DB:VIEWER
#   log-shipper auto   compose 38
#   cache       multi  compose 33  SECRETS=DEFAULT
#   proxy       single compose 40  PLACEMENT=edge
#   vault       single compose 45  SECRETS=ROOT
#   gitops      single k3s     50  REQUIRES=vault
#   app-cluster multi  k3s     60  REQUIRES=gitops
# shellcheck disable=SC2016,SC2154 # scripts expand in the child bash; $stderr is set by bats

setup() {
  load helpers
  copy_catalog
}

# on_fixture SCRIPT — runs SCRIPT after loading $CAT; stdout only in $output.
on_fixture() {
  run --separate-stderr in_catalog "catalog_load '$CAT'; $1"
}

# --- loading and validation -------------------------------------------------

@test "the repository catalog is valid" {
  run in_catalog "catalog_load '$REPO_ROOT/catalog'"
  [ "$status" -eq 0 ]
}

@test "the valid fixture loads without errors" {
  run in_catalog "catalog_load '$CAT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "loading does not leak service.conf variables into the shell" {
  run in_catalog "catalog_load '$CAT'; [[ -z \${ID+x} && -z \${NAME+x} && -z \${SCOPE+x} ]]"
  [ "$status" -eq 0 ]
}

@test "catalog_get returns a field value" {
  on_fixture 'catalog_get db PRIORITY'
  [ "$output" = 30 ]
}

@test "rejects a missing catalog directory" {
  expect_invalid "catalog directory not found" "$BATS_TEST_TMPDIR/none"
}

@test "rejects a catalog without services" {
  mkdir "$BATS_TEST_TMPDIR/empty"
  expect_invalid "no services found" "$BATS_TEST_TMPDIR/empty"
}

@test "rejects ID that differs from the directory name" {
  set_key cache ID other
  expect_invalid "must match directory name 'cache'"
}

@test "rejects ID that is not lowercase" {
  mv "$CAT/cache" "$CAT/Cache"
  set_key Cache ID Cache
  expect_invalid "ID must be lowercase"
}

@test "rejects a missing required key" {
  sed -i '/^NAME=/d' "$CAT/cache/service.conf"
  expect_invalid "missing required key NAME"
}

@test "rejects an unknown SCOPE" {
  set_key cache SCOPE everywhere
  expect_invalid "SCOPE must be"
}

@test "rejects an unknown runtime" {
  set_key cache RUNTIMES '"compose docker"'
  expect_invalid "unknown runtime docker"
}

@test "rejects PLACEMENT other than edge" {
  set_key cache PLACEMENT cloud
  expect_invalid "PLACEMENT must be empty or edge"
}

@test "rejects PRIORITY reserved for common steps" {
  set_key cache PRIORITY 11
  expect_invalid "PRIORITY must be a two-digit number 12-99"
}

@test "rejects a non-numeric PRIORITY" {
  set_key cache PRIORITY high
  expect_invalid "PRIORITY must be a two-digit number 12-99"
}

@test "rejects a port out of range" {
  set_key cache PORTS 70000
  expect_invalid "invalid port 70000"
}

@test "rejects an invalid public port" {
  set_key proxy PUBLIC_PORTS 0
  expect_invalid "PUBLIC_PORTS: invalid port 0"
}

@test "rejects PUBLIC_PORTS on a service without PLACEMENT=edge" {
  set_key cache PUBLIC_PORTS 8080
  expect_invalid "PUBLIC_PORTS is allowed only with PLACEMENT=edge"
}

@test "rejects an auto exporter with PRIORITY other than 39" {
  set_key db-exporter PRIORITY 31
  expect_invalid "auto exporters must have PRIORITY=39"
}

@test "an always exporter (node-exporter) keeps its own priority" {
  mv "$CAT/node-agent" "$CAT/node-exporter"
  set_key node-exporter ID node-exporter
  run in_catalog "catalog_load '$CAT'"
  [ "$status" -eq 0 ]
}

@test "rejects an invalid secret role" {
  set_key cache SECRETS viewer
  expect_invalid "SECRETS: invalid role viewer"
}

@test "rejects USES_SECRETS without a role" {
  set_key db-exporter USES_SECRETS DB
  expect_invalid "expected PREFIX:ROLE"
}

@test "rejects USES_SECRETS of an unknown service" {
  set_key db-exporter USES_SECRETS '"NO_SUCH:VIEWER"'
  expect_invalid "refers to unknown service no-such"
}

@test "rejects an unknown key" {
  echo 'PRIORTY=30' >>"$CAT/cache/service.conf"
  expect_invalid "unknown key PRIORTY"
}

@test "rejects a duplicate key" {
  echo 'NAME="again"' >>"$CAT/cache/service.conf"
  expect_invalid "duplicate key NAME"
}

@test "rejects REQUIRES of an unknown service" {
  set_key gitops REQUIRES ghost
  expect_invalid "REQUIRES unknown service ghost"
}

@test "rejects AUTO_ADD of an unknown service" {
  set_key db AUTO_ADD ghost
  expect_invalid "AUTO_ADD unknown service ghost"
}

@test "rejects AUTO_ADD of a service that is not auto" {
  set_key db AUTO_ADD cache
  expect_invalid "AUTO_ADD target cache must have SCOPE=auto"
}

@test "does not execute command substitution in service.conf" {
  local pwned="$BATS_TEST_TMPDIR/pwned"
  set_key cache NAME "\"\$(touch $pwned)\""
  set_key vault NAME "\`touch $pwned\`"
  expect_invalid "expected KEY=value"
  [ ! -e "$pwned" ]
}

@test "reports errors from every broken service, not only the first" {
  set_key cache SCOPE bad
  set_key vault RUNTIMES bad
  expect_invalid "cache/service.conf: SCOPE must be"
  [[ $output == *"vault/service.conf: RUNTIMES: unknown runtime bad"* ]]
}

# --- selection ---------------------------------------------------------------

@test "compose machine is offered only compose services, sorted by priority" {
  on_fixture 'catalog_selectable compose 0'
  [ "${lines[*]}" = "db cache vault" ]
}

@test "k3s machine is offered k3s and compose services" {
  on_fixture 'catalog_selectable k3s 0'
  [ "${lines[*]}" = "db cache vault gitops app-cluster" ]
}

@test "single services already assigned are hidden, multi ones stay" {
  on_fixture 'catalog_selectable k3s 0 db cache gitops'
  [ "${lines[*]}" = "cache vault app-cluster" ]
}

@test "PLACEMENT=edge services are never offered for selection" {
  on_fixture 'catalog_selectable compose 1'
  [[ " ${lines[*]} " != *" proxy "* ]]
}

@test "edge gets always and PLACEMENT=edge services as forced" {
  on_fixture 'catalog_forced compose 1'
  [ "${lines[*]}" = "node-agent proxy" ]
}

@test "non-edge machine gets only always services as forced" {
  on_fixture 'catalog_forced k3s 0'
  [ "${lines[*]}" = "node-agent" ]
}

@test "rejects an unknown machine runtime" {
  on_fixture 'catalog_selectable docker 0'
  [ "$status" -eq 1 ]
  [[ $stderr == *"machine runtime must be compose or k3s"* ]]
}

@test "rejects is_edge other than 0 or 1" {
  on_fixture 'catalog_forced compose yes'
  [ "$status" -eq 1 ]
  [[ $stderr == *"is_edge must be 0 or 1"* ]]
}

@test "rejects an unknown assigned service" {
  on_fixture 'catalog_selectable compose 0 ghost'
  [ "$status" -eq 1 ]
  [[ $stderr == *"unknown service: ghost"* ]]
}

# --- AUTO_ADD, REQUIRES, ordering ---------------------------------------------

@test "expand adds AUTO_ADD services recursively" {
  on_fixture 'catalog_expand db'
  [ "${lines[*]}" = "db db-exporter log-shipper" ]
}

@test "expand does not duplicate services" {
  on_fixture 'catalog_expand db db-exporter log-shipper db'
  [ "${lines[*]}" = "db db-exporter log-shipper" ]
}

@test "expand terminates on an AUTO_ADD cycle" {
  set_key log-shipper AUTO_ADD db-exporter
  on_fixture 'catalog_expand db'
  [ "$status" -eq 0 ]
  [ "${lines[*]}" = "db db-exporter log-shipper" ]
}

@test "missing_requires reports every unmet requirement" {
  on_fixture 'catalog_missing_requires app-cluster gitops db-exporter'
  [ "$status" -eq 1 ]
  [ "${lines[*]}" = "gitops vault db-exporter db" ]
}

@test "missing_requires succeeds when all requirements are selected" {
  on_fixture 'catalog_missing_requires gitops vault'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sort orders by priority" {
  on_fixture 'catalog_sort app-cluster db-exporter db log-shipper'
  [ "${lines[*]}" = "db log-shipper db-exporter app-cluster" ]
}

@test "sort breaks priority ties by id" {
  set_key vault PRIORITY 33
  on_fixture 'catalog_sort vault cache'
  [ "${lines[*]}" = "cache vault" ]
}

@test "sort rejects an unknown service" {
  on_fixture 'catalog_sort db ghost'
  [ "$status" -eq 1 ]
  [[ $stderr == *"unknown service: ghost"* ]]
}

@test "repository catalog: postgresql brings its exporter, argocd needs openbao" {
  run --separate-stderr in_catalog "catalog_load '$REPO_ROOT/catalog'
    catalog_sort \$(catalog_expand postgresql)
    catalog_missing_requires argocd || echo missing"
  [ "${lines[*]}" = "postgresql postgres-exporter argocd openbao missing" ]
}

@test "FIXED_PORTS must be ports of the service" {
  set_key db PORTS '"5432"'
  echo 'FIXED_PORTS="5433"' >>"$CAT/db/service.conf"
  expect_invalid "FIXED_PORTS: 5433 is not one of the service's PORTS or PUBLIC_PORTS"
}
