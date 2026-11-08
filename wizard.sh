#!/usr/bin/env bash
# Homelab wizard: asks about machines, admin devices and services, then writes state.yaml,
# secrets, WireGuard and CA files into the output directory (and nowhere else).
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/wizard.sh
source "$ROOT/lib/wizard.sh"

usage() {
  cat <<'EOF'
Usage: wizard.sh [--gitops-repo URL] [--out DIR] [--answers FILE] [--catalog DIR]

  --gitops-repo URL  homelab-gitops repository for ArgoCD (required for a new state)
  --out DIR          output directory (default: out/ next to wizard.sh); an existing
                     DIR/state.yaml is loaded and only new machines are asked about
  --answers FILE     non-interactive: answers as KEY=value (see tests/fixtures/answers/)
  --catalog DIR      service catalog (default: catalog/ next to wizard.sh)
EOF
}

main() {
  local repo='' out_dir="$ROOT/out" answers='' catalog="$ROOT/catalog"
  while (($#)); do
    case $1 in
      --gitops-repo | --out | --answers | --catalog)
        (($# >= 2)) || die "$1 needs a value"
        case $1 in
          --gitops-repo) repo=$2 ;;
          --out) out_dir=$2 ;;
          --answers) answers=$2 ;;
          --catalog) catalog=$2 ;;
        esac
        shift 2
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
  wizard_check_tools || die "install the missing tools first"
  catalog_load "$catalog" || die "invalid catalog: $catalog"
  if [[ -n $answers ]]; then ui_load_answers "$answers" || die "invalid answers file: $answers"; fi
  wizard_collect "$out_dir" "$repo" || die "wizard stopped"
  wizard_generate "$out_dir" || die "nothing written to $out_dir/state.yaml; fix the errors above and run again"
}

main "$@"
