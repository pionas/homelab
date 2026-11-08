#!/usr/bin/env bash
# Runs the install steps for real inside a disposable Debian + systemd container, never on this
# machine: a package for one machine (compose, then k3s) is installed three times — first run,
# second run (every step must be skipped as done), --force (every step runs again).
#
# The container is NOT --privileged: a privileged container could change this machine's clock
# (chrony), kernel-wide sysctls and kernel modules. It gets NET_ADMIN (iptables, UFW and WireGuard
# act only in the container's own network namespace) and SYS_ADMIN with a private cgroup
# namespace for systemd; no host directory and no Docker socket is mounted.
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
RUNTIME_OPTS=(--cgroupns=private --tmpfs /run --tmpfs /run/lock
  --cap-add NET_ADMIN --cap-add SYS_ADMIN --security-opt apparmor=unconfined)

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

start_container() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" --hostname edge "${RUNTIME_OPTS[@]}" "$IMAGE" >/dev/null
  # degraded is fine (a unit irrelevant here may fail); only "starting" past the timeout is not.
  local state
  state=$(timeout "$BOOT_TIMEOUT" docker exec "$NAME" systemctl is-system-running --wait 2>/dev/null || true)
  [[ $state == running || $state == degraded ]] || die "systemd in the container did not start (state: ${state:-none})"
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

docker build -q -t "$IMAGE" tests/container >/dev/null
scenario compose
scenario k3s
