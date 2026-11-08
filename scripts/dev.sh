#!/usr/bin/env bash
# Developer commands for this repo. Usage: scripts/dev.sh <command>... (see `help`).
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=common/lib.sh
source common/lib.sh

declare -A INSTALL_HINT=(
  [git]="sudo apt install git"
  [shellcheck]="sudo apt install shellcheck"
  [shfmt]="sudo apt install shfmt"
  [bats]="sudo apt install bats"
  [yq]="mikefarah/yq from https://github.com/mikefarah/yq/releases (not the Debian yq package)"
)

usage() {
  cat <<'EOF'
Usage: scripts/dev.sh <command>...

Commands (run in the given order, stop at the first failure):
  lint       shellcheck + shfmt -d -i 2 -ci on all tracked shell files and service.conf
  test       bats tests/unit
  golden     generate from tests/golden/*/state.yaml and compare (not implemented yet)
  validate   docker compose config, kubeconform, yq on generated files (not implemented yet)
  container  install steps in a Debian systemd container (not implemented yet)
  help       show this help
EOF
}

need() {
  local tool missing=0
  for tool in "$@"; do
    command -v "$tool" >/dev/null && continue
    log_error "missing tool: $tool (install: ${INSTALL_HINT[$tool]:-see docs})"
    missing=1
  done
  ((missing == 0)) || exit 1
}

# Tracked and new (not ignored) files matching the given pathspecs.
repo_files() { git ls-files --cached --others --exclude-standard -- "$@"; }

cmd_lint() {
  need git shellcheck shfmt
  local -a scripts confs
  mapfile -t scripts < <(repo_files '*.sh' '*.bats')
  mapfile -t confs < <(repo_files '*/service.conf')
  local rc=0
  shellcheck -x "${scripts[@]}" || rc=1
  # service.conf is plain KEY=value data, so unused-variable warnings do not apply.
  if ((${#confs[@]})); then shellcheck -s bash -e SC2034 "${confs[@]}" || rc=1; fi
  shfmt -d -i 2 -ci "${scripts[@]}" || rc=1
  ((rc == 0)) && log_info "lint OK"
  return "$rc"
}

cmd_test() {
  need bats yq
  compgen -G 'tests/unit/*.bats' >/dev/null || die "no tests found in tests/unit"
  bats tests/unit
}

cmd_golden() { log_warn "golden: not implemented yet (issue #10)"; }
cmd_validate() { log_warn "validate: not implemented yet (issue #10)"; }
cmd_container() { log_warn "container: not implemented yet (issue #13)"; }

main() {
  if (($# == 0)); then
    usage >&2
    exit 2
  fi
  local cmd
  for cmd in "$@"; do
    case $cmd in
      lint | test | golden | validate | container) ;;
      help | -h | --help)
        usage
        exit 0
        ;;
      *)
        log_error "unknown command: $cmd"
        usage >&2
        exit 2
        ;;
    esac
  done
  for cmd in "$@"; do "cmd_$cmd"; done
}

main "$@"
