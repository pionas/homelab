#!/usr/bin/env bats
# Tests for the install steps in common/ — ALWAYS with --dry-run. Read-only commands (sshd, wg,
# systemctl is-*, getent, modinfo, id) are fakes at the front of PATH, driven by FAKE_* variables;
# commands that change the system go through `run` and are only printed.
# shellcheck disable=SC2016,SC2154 # scripts expand in the child bash; $stderr is set by bats

setup() {
  load helpers
  T=$BATS_TEST_TMPDIR
  PKG=$T/pkg
  mkdir -p "$PKG/common" "$PKG/node" "$T/bin" "$T/state"
  cp "$REPO_ROOT"/common/*.sh "$PKG/common/"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=test-root -days 1 \
    -keyout "$T/root.key" -out "$PKG/common/root_ca.crt" 2>/dev/null
  node_env compose 51820 22 "node-agent postgresql" "9100 5432" ""
  printf '[Interface]\nAddress = 10.100.10.101/24\nPrivateKey = x\nListenPort = 51820\n' >"$PKG/node/wg0.conf"
  echo 'X=1' >"$PKG/node/secrets.env"
  chmod 600 "$PKG/node/secrets.env"
  printf 'ID=debian\n' >"$T/os-release"
  ssh-keygen -q -t ed25519 -N '' -f "$T/admin" && cp "$T/admin.pub" "$T/authorized_keys"
  fakes
  export HOMELAB_STATE_DIR=$T/state HOMELAB_NODE_DIR=$PKG/node HOMELAB_OS_RELEASE=$T/os-release
  export HOMELAB_ADMIN_KEYS=$T/authorized_keys
  unset SSH_CONNECTION
}

# node_env RUNTIME WG_PORT SSH_PORT SERVICES PORTS PUBLIC_PORTS
node_env() {
  printf 'NODE_NAME=vps1\nWG_IP=10.100.10.101\nWG_PORT=%s\nSSH_PORT=%s\nRUNTIME=%s\nOS=debian\nSERVICES="%s"\nPORTS="%s"\nPUBLIC_PORTS="%s"\n' \
    "$2" "$3" "$1" "$4" "$5" "$6" >"$PKG/node/node.env"
  sed -i "s/^ListenPort = .*/ListenPort = $2/" "$PKG/node/wg0.conf" 2>/dev/null || true
}

fake() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/bin/$1" && chmod +x "$T/bin/$1"; }

fakes() {
  fake sshd 'case $1 in -T) echo "port ${FAKE_SSHD_PORT:-22}" ;; esac'
  fake getent '[[ -z ${FAKE_NO_NET:-} ]]'
  fake modinfo '[[ -z ${FAKE_NO_WG_MODULE:-} ]]'
  fake id '[[ $1 == -u && -n ${FAKE_ADMIN_EXISTS:-} ]] && echo 1000 || exit 1'
  # is-active/is-enabled answer from FAKE_ACTIVE / FAKE_ENABLED (space-separated unit names).
  fake systemctl 'u=${@: -1}; case $1 in is-active) [[ " ${FAKE_ACTIVE:-} " == *" $u "* ]] ;; is-enabled) [[ " ${FAKE_ENABLED:-} " == *" $u "* ]] ;; *) echo "unexpected systemctl $*" >&2; exit 9 ;; esac'
  # latest-handshakes: FAKE_HANDSHAKES "pubkey:age_seconds ..." (age "never" = 0); allowed-ips: FAKE_PEERS "pubkey:ip ...".
  fake wg 'now=$(date +%s); [[ -z ${FAKE_WG_DOWN:-} ]] || exit 1
    case "$3" in
      latest-handshakes) for e in ${FAKE_HANDSHAKES:-}; do a=${e#*:}; [[ $a == never ]] && t=0 || t=$((now - a)); printf "%s\t%s\n" "${e%%:*}" "$t"; done ;;
      allowed-ips) for e in ${FAKE_PEERS:-}; do printf "%s\t%s/32\n" "${e%%:*}" "${e#*:}"; done ;;
    esac'
}

# step NAME [ARG...] — runs common/NAME.sh with --dry-run and the fakes first in PATH.
step() {
  run --separate-stderr env PATH="$T/bin:$PATH" bash "$PKG/common/$1.sh" --dry-run "${@:2}"
}

# line_of PATTERN — number of the first output line matching PATTERN (grep -E), empty if none.
line_of() { printf '%s\n' "$output" | grep -nE -m1 -- "$1" | cut -d: -f1; }

# before A B — the first line matching A comes before the first matching B (both present).
before() {
  local a b
  a=$(line_of "$1")
  b=$(line_of "$2")
  [[ -n $a && -n $b ]] && ((a < b))
}

# --- 00 preflight -------------------------------------------------------------

@test "00: passes on Debian with a complete package and changes nothing" {
  step 00-preflight
  [ "$status" -eq 0 ]
  [[ $stderr == *"preflight OK for vps1"* ]]
  [[ $output != *"[dry-run]"* ]]
}

@test "00: reports every problem: OS, network, wireguard module, package files" {
  printf 'ID=fedora\n' >"$T/os-release"
  rm "$PKG/node/wg0.conf"
  FAKE_NO_NET=1 FAKE_NO_WG_MODULE=1 step 00-preflight
  [ "$status" -eq 1 ]
  [[ $stderr == *"unsupported system 'fedora'"* ]]
  [[ $stderr == *"cannot resolve deb.debian.org"* ]]
  [[ $stderr == *"kernel module wireguard is not available"* ]]
  [[ $stderr == *"missing package file: $PKG/node/wg0.conf"* ]]
}

@test "00: incomplete node.env stops it" {
  sed -i '/^SSH_PORT=/d' "$PKG/node/node.env"
  step 00-preflight
  [ "$status" -eq 1 ]
  [[ $stderr == *"required variable SSH_PORT is missing"* ]]
}

@test "00: detects the SSH session and warns when sshd will move to another port" {
  node_env compose 443 2222 "" "" ""
  SSH_CONNECTION="203.0.113.5 50000 198.51.100.7 22" step 00-preflight
  [ "$status" -eq 0 ]
  [[ $stderr == *"SSH session from 203.0.113.5 to port 22"* ]]
  [[ $stderr == *"sshd moves to port 2222 in step 01"* ]]
}

# --- 01 base system -----------------------------------------------------------

@test "01: packages, chrony, hostname, timezone, unattended-upgrades without reboot, fail2ban, ip_forward" {
  step 01-base
  [ "$status" -eq 0 ]
  [[ $output == *"apt-get install -y chrony fail2ban unattended-upgrades wireguard"* ]]
  [[ $output == *"[dry-run] hostnamectl set-hostname vps1"* ]]
  [[ $output == *"[dry-run] timedatectl set-timezone Etc/UTC"* ]]
  [[ $output == *'Unattended-Upgrade::Automatic-Reboot "false";'* ]]
  [[ $output == *"ignoreip = 127.0.0.1/8 ::1 10.100.10.0/24"* ]]
  [[ $output == *"net.ipv4.ip_forward = 1"* ]]
}

@test "01: user -> verified authorized_keys -> sudo -> sshd hardening -> sshd -t -> reload" {
  step 01-base
  [ "$status" -eq 0 ]
  before 'useradd --create-home' 'install -m 600 -o admin -g admin .*authorized_keys'
  before 'authorized_keys' 'write /etc/sudoers.d/90-homelab-admin'
  before 'visudo -cf' 'write /etc/ssh/sshd_config.d/10-homelab.conf'
  before 'PasswordAuthentication no' '\[dry-run\] sshd -t'
  before '\[dry-run\] sshd -t' 'systemctl reload ssh'
  [[ $output != *"restart ssh"* ]]
  [[ $output == *"admin ALL=(ALL) NOPASSWD:ALL"* ]]
}

@test "01: no valid admin key stops before anything changes" {
  echo 'not a key' >"$T/authorized_keys"
  step 01-base
  [ "$status" -eq 1 ]
  [[ $stderr == *"no valid SSH public key in $T/authorized_keys"* ]]
  [[ $output != *"sshd_config.d"* && $output != *useradd* ]]
}

@test "01: existing admin user is reused" {
  FAKE_ADMIN_EXISTS=1 step 01-base
  [ "$status" -eq 0 ]
  [[ $output != *useradd* ]]
  [[ $stderr == *"user admin exists"* ]]
}

@test "01: SSH_PORT from node.env goes to sshd and fail2ban (2222), nothing hard-coded" {
  node_env compose 443 2222 "" "" ""
  step 01-base
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run]   Port 2222"* ]]
  [[ $output == *"[dry-run]   port = 2222"* ]]
  [[ $output != *"Port 22"$'\n'* ]]
  [[ $output != *"port = 22"$'\n'* ]]
}

@test "01: socket-activated sshd (Ubuntu) gets daemon-reload + socket restart instead of reload" {
  FAKE_ENABLED=ssh.socket step 01-base
  [ "$status" -eq 0 ]
  before '\[dry-run\] sshd -t' 'systemctl daemon-reload'
  [[ $output == *"systemctl restart ssh.socket"* ]]
  [[ $output != *"systemctl reload ssh"* ]]
}

@test "01: a done step is skipped; --force reruns it" {
  mkdir -p "$T/state/done" && touch "$T/state/done/01"
  step 01-base
  [ "$status" -eq 0 ]
  [[ $output != *apt-get* ]]
  step 01-base --force
  [[ $output == *apt-get* ]]
}
