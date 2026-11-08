#!/usr/bin/env bash
# shellcheck shell=bash
# Questions only: every ui_* function asks one question and leaves the answer in UI_ANSWER
# (not stdout, so callers do not run it in a subshell and answer tracking survives).
# Each question has a KEY; answers come from an answers file (ui_load_answers), else from whiptail
# on a terminal, else from plain `read` on stdin. Prompts and errors go to stderr.

# shellcheck source=common/lib.sh
source "${BASH_SOURCE[0]%/*}/../common/lib.sh"

# KEY=value or KEY="value", several per line; no $, backticks or backslashes, so nothing can expand.
# shellcheck disable=SC2016 # literal regex, nothing to expand
_UI_PAIR_RE='^([A-Z][A-Z0-9_]*)=("([^"$`\\]*)"|([^"$`\\[:space:]#]*))[[:space:]]*(.*)$'

declare -gA _UI_ANSWERS=() _UI_USED=()
declare -g _UI_FILE='' UI_ANSWER=''

# ui_load_answers FILE — answers file mode. The file is data from the user: parsed, never sourced.
ui_load_answers() {
  local file=$1 line rest n=0 rc=0
  _UI_ANSWERS=()
  _UI_USED=()
  [[ -r $file ]] || {
    log_error "answers file not readable: $file"
    return 1
  }
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    rest=${line#"${line%%[![:space:]]*}"}
    while [[ -n $rest && $rest != \#* ]]; do
      if ! [[ $rest =~ $_UI_PAIR_RE ]]; then
        log_error "$file:$n: expected KEY=value or KEY=\"value\" without \$, \` or \\"
        rc=1
        break
      fi
      local k=${BASH_REMATCH[1]} v
      if [[ ${BASH_REMATCH[2]} == \"* ]]; then v=${BASH_REMATCH[3]}; else v=${BASH_REMATCH[4]}; fi
      rest=${BASH_REMATCH[5]}
      [[ -z ${_UI_ANSWERS[$k]+set} ]] || {
        log_error "$file:$n: duplicate key $k"
        rc=1
      }
      _UI_ANSWERS[$k]=$v
    done
  done <"$file"
  ((rc == 0)) && _UI_FILE=$file
  return "$rc"
}

# ui_unused_answers — keys in the answers file no question asked for (usually typos).
ui_unused_answers() {
  local k
  for k in "${!_UI_ANSWERS[@]}"; do [[ -n ${_UI_USED[$k]-} ]] || echo "$k"; done | sort
}

_ui_whiptail() { [[ -t 0 && -t 2 ]] && type -P whiptail >/dev/null; }

# _ui_from_file KEY DEFAULT — answer from the file, the default when the key is absent.
_ui_from_file() {
  _UI_USED[$1]=1
  if [[ -n ${_UI_ANSWERS[$1]+set} ]]; then
    UI_ANSWER=${_UI_ANSWERS[$1]}
  elif [[ -n $2 ]]; then
    UI_ANSWER=$2
  else
    log_error "$_UI_FILE: missing answer $1"
    return 1
  fi
}

_ui_read() {
  local prompt=$1 default=$2
  printf '%s%s: ' "$prompt" "${default:+ [$default]}" >&2
  IFS= read -r UI_ANSWER || {
    log_error "no answer for: $prompt"
    return 1
  }
  UI_ANSWER=${UI_ANSWER:-$default}
}

# _ui_dialog ARGS... — whiptail writes the answer to stderr; swap it onto stdout.
_ui_dialog() { UI_ANSWER=$(whiptail --title homelab "$@" 3>&1 1>&2 2>&3); }

# ui_input KEY PROMPT [DEFAULT]
ui_input() {
  local key=$1 prompt=$2 default=${3:-}
  if [[ -n $_UI_FILE ]]; then
    _ui_from_file "$key" "$default"
  elif _ui_whiptail; then
    _ui_dialog --inputbox "$prompt" 10 72 "$default"
  else
    _ui_read "$prompt" "$default"
  fi
}

# ui_menu KEY PROMPT DEFAULT OPTION... — one of OPTION.
ui_menu() {
  local key=$1 prompt=$2 default=$3 opt
  shift 3
  if [[ -n $_UI_FILE ]]; then
    _ui_from_file "$key" "$default" || return 1
  elif _ui_whiptail; then
    local -a items=()
    for opt in "$@"; do items+=("$opt" ""); done
    _ui_dialog --default-item "$default" --menu "$prompt" 15 72 6 "${items[@]}" || return 1
  else
    _ui_read "$prompt ($*)" "$default" || return 1
  fi
  [[ " $* " == *" $UI_ANSWER "* ]] || {
    log_error "$key: '$UI_ANSWER' is not one of: $*"
    return 1
  }
}

# ui_checklist KEY PROMPT OPTION... — any subset of OPTION, space-separated (absent key = none).
ui_checklist() {
  local key=$1 prompt=$2 opt
  shift 2
  if [[ -n $_UI_FILE ]]; then
    _UI_USED[$key]=1
    UI_ANSWER=${_UI_ANSWERS[$key]-}
  elif ! (($#)); then
    UI_ANSWER=''
  elif _ui_whiptail; then
    local -a items=()
    for opt in "$@"; do items+=("$opt" "" OFF); done
    _ui_dialog --separate-output --checklist "$prompt" 20 72 12 "${items[@]}" || return 1
    UI_ANSWER=${UI_ANSWER//$'\n'/ }
  else
    _ui_read "$prompt (space-separated: $*)" '' || return 1
  fi
  for opt in $UI_ANSWER; do
    [[ " $* " == *" $opt "* ]] || {
      log_error "$key: '$opt' is not one of: ${*:-(none)}"
      return 1
    }
  done
}

# ui_yesno KEY PROMPT DEFAULT — UI_ANSWER is yes or no.
ui_yesno() {
  local key=$1 prompt=$2 default=$3
  if [[ -n $_UI_FILE ]] || ! _ui_whiptail; then
    ui_menu "$key" "$prompt" "$default" yes no
    return
  fi
  local -a opt=()
  [[ $default == no ]] && opt=(--defaultno)
  if whiptail --title homelab "${opt[@]}" --yesno "$prompt" 10 72; then UI_ANSWER=yes; else UI_ANSWER=no; fi
}
