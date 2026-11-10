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
  [docker]="https://docs.docker.com/engine/install/debian/"
  [kubeconform]="https://github.com/yannh/kubeconform/releases"
  [step]="https://github.com/smallstep/cli/releases"
  [yq]="mikefarah/yq from https://github.com/mikefarah/yq/releases (not the Debian yq package)"
)

usage() {
  cat <<'EOF'
Usage: scripts/dev.sh <command>...

Commands (run in the given order, stop at the first failure):
  lint       shellcheck + shfmt -d -i 2 -ci on all tracked shell files and service.conf
  test       bats tests/unit
  golden     run the wizard on tests/golden/*/answers.txt (catalog: the scenario's file
             `catalog` or tests/fixtures/catalog-wizard) and compare with expected/
             (GOLDEN_UPDATE=1 replaces expected/ with the new result)
  validate   docker compose config, kubeconform -strict, yq (YAML, JSON) on the golden scenarios' output
  container  install steps for real in a disposable Debian systemd container (tests/container)
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

GOLDEN_CATALOG=tests/fixtures/catalog-wizard
GOLDEN_REPO=git@example.com:pionas/homelab-gitops.git
WIZARD_TOOLS=(yq wg openssl qrencode step ssh-keygen perl)

# Deterministic generators for golden runs; exported so wizard.sh can call them.
_golden_next() {
  local n
  n=$(($(<"$GOLDEN_DIR/$1") + 1))
  echo "$n" >"$GOLDEN_DIR/$1"
  echo "$n"
}
golden_secret() { echo "golden-secret-$(_golden_next secret-n)"; }
golden_wg_key() { printf 'golden-wg-%s' "$(_golden_next wg-n)" | openssl dgst -sha256 -binary | base64; }
# The deploy key and the bcrypt salt are random by nature; golden runs use fixed test values.
golden_gitops_key() { cp "$GOLDEN_FIXTURES/gitops/deploy_key" "$1" && cp "$GOLDEN_FIXTURES/gitops/deploy_key.pub" "$1.pub"; }
golden_salt() { echo goldengoldengoldengold; }
export -f _golden_next golden_secret golden_wg_key golden_gitops_key golden_salt

# _golden_generate SCENARIO WORK — runs the wizard on SCENARIO/answers.txt into WORK/out.
_golden_generate() {
  local scenario=$1 work=$2 catalog=$GOLDEN_CATALOG
  # A scenario may name another catalog (repo-relative directory) in its file `catalog`.
  if [[ -f $scenario/catalog ]]; then
    catalog=$(<"$scenario/catalog")
    [[ $catalog =~ ^[a-z0-9/_-]+$ && -d $catalog ]] || die "$scenario/catalog: not a repo directory: $catalog"
  fi
  echo 0 >"$work/secret-n"
  echo 0 >"$work/wg-n"
  GOLDEN_DIR=$work GOLDEN_FIXTURES=$PWD/tests/fixtures SECRETS_GENERATOR=golden_secret WG_KEYGEN=golden_wg_key \
    GITOPS_KEYGEN=golden_gitops_key ARGOCD_SALT_GENERATOR=golden_salt ./wizard.sh \
    --catalog "$catalog" --gitops-repo "$GOLDEN_REPO" --answers "$scenario/answers.txt" \
    --out "$work/out" >"$work/wizard.log" 2>&1 || {
    cat "$work/wizard.log" >&2
    log_error "$scenario: wizard failed"
    return 1
  }
}

# _golden_normalize OUT DEST — a comparable copy: step-cli makes new CA keys and timestamps on
# every run, so CA files are replaced by CA_FILES.list and archives by their file lists.
_golden_normalize() {
  local out=$1 dest=$2 f
  cp -a "$out" "$dest"
  (
    cd "$dest"
    find . -mindepth 1 -printf '%m %P\n' | sort -k2 >MODES.list
    # ArgoCD cluster Secrets embed the cluster CAs, so they are compared by name only as well.
    find . -type f \( -path '*/ca/*' -o -path '*/k3s-ca/*' -o -name root_ca.crt -o -path '*/argocd/clusters/*' \) -printf '%P\n' |
      sort >CA_FILES.list
    xargs -r rm -f <CA_FILES.list
    # Verbatim copies of the repo's common/*.sh; the archive lists still show they are packaged.
    rm -f common/*.sh
    for f in *.tar.gz; do
      [[ -e $f ]] || continue
      tar -tzf "$f" | sort >"$f.list"
      rm -f "$f"
    done
    find . -mindepth 1 -type d -empty -delete
  )
}

cmd_golden() {
  need "${WIZARD_TOOLS[@]}" tar
  local scenario work rc=0
  for scenario in tests/golden/*/; do
    scenario=${scenario%/}
    work=$(mktemp -d)
    if _golden_generate "$scenario" "$work"; then
      _golden_normalize "$work/out" "$work/actual"
      if [[ ${GOLDEN_UPDATE:-0} == 1 ]]; then
        rm -rf "$scenario/expected"
        cp -a "$work/actual" "$scenario/expected"
        log_info "golden $scenario: expected/ updated"
      elif diff -r "$scenario/expected" "$work/actual"; then
        log_info "golden $scenario OK"
      else
        log_error "golden $scenario differs from expected/ (review, then GOLDEN_UPDATE=1 to accept)"
        rc=1
      fi
    else
      rc=1
    fi
    rm -rf "$work"
  done
  return "$rc"
}

cmd_validate() {
  need "${WIZARD_TOOLS[@]}" docker kubeconform
  local scenario work f rc=0
  local -a manifests
  for scenario in tests/golden/*/; do
    scenario=${scenario%/}
    work=$(mktemp -d)
    if ! _golden_generate "$scenario" "$work"; then
      rc=1
      rm -rf "$work"
      continue
    fi
    manifests=()
    while IFS= read -r f; do
      yq '.' "$f" >/dev/null || {
        log_error "invalid YAML: ${f#"$work/out/"}"
        rc=1
      }
      if [[ ${f##*/} == docker-compose.yml ]]; then
        docker compose -f "$f" config -q || {
          log_error "docker compose config failed: ${f#"$work/out/"}"
          rc=1
        }
      elif grep -q '^apiVersion:' "$f" && grep -q '^kind:' "$f"; then
        manifests+=("$f")
      fi
    done < <(find "$work/out" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
    while IFS= read -r f; do
      yq -p json '.' "$f" >/dev/null || {
        log_error "invalid JSON: ${f#"$work/out/"}"
        rc=1
      }
    done < <(find "$work/out" -type f -name '*.json' | sort)
    if ((${#manifests[@]})); then
      # CRDs (ArgoCD Application, External Secrets ClusterSecretStore) from the community CRD catalog.
      kubeconform -strict -summary -cache "$(mkdir -p "$HOME/.cache/kubeconform" && echo "$HOME/.cache/kubeconform")" \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
        "${manifests[@]}" || rc=1
    fi
    ((rc == 0)) && log_info "validate $scenario OK"
    rm -rf "$work"
  done
  return "$rc"
}
# Install steps for real, inside a disposable container (never on this machine).
cmd_container() {
  need docker "${WIZARD_TOOLS[@]}"
  tests/container/run.sh
}

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
