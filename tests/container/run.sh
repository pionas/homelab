#!/usr/bin/env bash
# Runs the install steps for real inside a disposable Debian + systemd container, never on this
# machine: a package for one machine (compose, then k3s) is installed three times — first run,
# second run (every step must be skipped as done), --force (every step runs again).
#
# Only with ROOTLESS Docker: there the container's root is this user mapped into a user namespace,
# so even --privileged gives capabilities inside that namespace only — it cannot set the host clock,
# kernel-wide sysctls or load kernel modules. With rootful Docker --privileged could do all of that,
# so the script refuses to run. No host directory and no Docker socket is mounted; the container
# has its own network namespace (UFW and WireGuard act only there) and a private cgroup namespace.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
# shellcheck source=common/lib.sh
source common/lib.sh

NAME=homelab-test
IMAGE=homelab-test:latest
BOOT_TIMEOUT=60
# The admin session comes over WireGuard, so step 03-ssh can prove the admin path and run.
ADMIN_SSH_CONNECTION="10.100.10.200 50000 10.100.10.100 22"
RUNTIME_OPTS=(--privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock)

WORK=$(mktemp -d)
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# package RUNTIME — wizard output for one machine "edge" with only node-exporter in the catalog
# (services without an installer yet would stop install.sh).
package() {
  mkdir -p "$WORK/catalog"
  cp -r catalog/node-exporter "$WORK/catalog/"
  printf 'MACHINES=1\nDEVICES="laptop:linux"\nM1_NAME=edge M1_ENDPOINT=192.0.2.10 M1_RUNTIME=%s\n' "$1" >"$WORK/answers-$1.txt"
  ./wizard.sh --catalog "$WORK/catalog" --out "$WORK/out-$1" --gitops-repo git@example.com:test/gitops.git \
    --answers "$WORK/answers-$1.txt" >"$WORK/wizard-$1.log" 2>&1 || {
    cat "$WORK/wizard-$1.log" >&2
    die "wizard failed for the $1 package"
  }
}

# container_diagnostics — state, exit code and console output, for when the container does not boot.
container_diagnostics() {
  docker inspect -f 'container: {{.State.Status}}, exit code {{.State.ExitCode}} {{.State.Error}}' "$NAME" >&2 || true
  docker logs --tail 40 "$NAME" >&2 2>&1 || true
}

start_container() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # -t gives systemd a console, so its boot messages show up in `docker logs`.
  docker run -d -t --name "$NAME" --hostname edge "${RUNTIME_OPTS[@]}" "$IMAGE" >/dev/null
  # systemctl answers "offline" until systemd runs as PID 1, so first wait for its runtime directory
  # (polling with a deadline), then let systemd itself wait for the end of the boot.
  local deadline=$((SECONDS + BOOT_TIMEOUT)) state
  until docker exec "$NAME" test -d /run/systemd/system 2>/dev/null; do
    if [[ $(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null) != true ]] || ((SECONDS >= deadline)); then
      container_diagnostics
      die "systemd in the container did not start"
    fi
    sleep 1
  done
  state=$(timeout "$((deadline - SECONDS + 1))" docker exec "$NAME" systemctl is-system-running --wait 2>/dev/null || true)
  # degraded is fine (a unit irrelevant here may fail); anything else is not.
  if [[ $state != running && $state != degraded ]]; then
    docker exec "$NAME" systemctl --failed --no-legend >&2 2>&1 || true
    container_diagnostics
    die "systemd in the container did not finish booting (state: ${state:-none})"
  fi
  if [[ $state == degraded ]]; then
    log_warn "container booted degraded; failed units:"
    docker exec "$NAME" systemctl --failed --no-legend >&2 2>&1 || true
  fi
}

# install RUNTIME LOG [ARG...] — runs the package's install.sh in the container.
install_run() {
  local log=$2
  shift 2
  docker exec -e SSH_CONNECTION="$ADMIN_SSH_CONNECTION" "$NAME" /root/pkg/edge/install.sh "$@" >"$log" 2>&1 || {
    cat "$log" >&2
    die "install.sh $* failed in the container"
  }
}

scenario() {
  local rt=$1
  log_info "container test: $rt machine"
  package "$rt"
  start_container
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/admin-$rt"
  docker exec "$NAME" mkdir -p /root/pkg
  docker cp "$WORK/admin-$rt.pub" "$NAME:/root/.ssh/authorized_keys"
  docker cp "$WORK/out-$rt/edge.tar.gz" "$NAME:/root/pkg/"
  docker exec "$NAME" tar -xzf /root/pkg/edge.tar.gz -C /root/pkg

  install_run "$rt" "$WORK/run1-$rt.log"
  grep -q 'verification of edge passed' "$WORK/run1-$rt.log" || die "$rt: step 90 did not pass"

  install_run "$rt" "$WORK/run2-$rt.log"
  # step() logs "step NN: fn" when it runs and "already done" when it skips.
  if grep -E '\[INFO\] step [0-9]{2}(-[a-z0-9-]+)?: ' "$WORK/run2-$rt.log"; then
    die "$rt: second run executed the steps above again (not idempotent)"
  fi
  grep -q 'already done, skipping' "$WORK/run2-$rt.log" || die "$rt: second run skipped nothing"

  install_run "$rt" "$WORK/run3-$rt.log" --force
  grep -qE '\[INFO\] step 01: ' "$WORK/run3-$rt.log" || die "$rt: --force did not rerun step 01"

  grep -h 'skipped in container' "$WORK"/run1-"$rt".log | sort -u | sed 's/^/  /' >&2 || true
  docker rm -f "$NAME" >/dev/null
  log_info "container test $rt OK (first run, idempotent second run, --force)"
}

if ! docker info --format '{{json .SecurityOptions}}' | grep -q 'name=rootless'; then
  die "Docker is not rootless: a --privileged test container could change this machine (clock," \
    "sysctls, kernel modules). Use rootless Docker (dockerd-rootless-setuptool.sh install)."
fi
docker build -q -t "$IMAGE" tests/container >/dev/null
scenario compose
scenario k3s
