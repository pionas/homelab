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
  printf 'ID=debian\nVERSION_CODENAME=trixie\n' >"$T/os-release"
  ssh-keygen -q -t ed25519 -N '' -f "$T/admin" && cp "$T/admin.pub" "$T/authorized_keys"
  fakes
  export HOMELAB_STATE_DIR=$T/state HOMELAB_NODE_DIR=$PKG/node HOMELAB_OS_RELEASE=$T/os-release
  export HOMELAB_ADMIN_KEYS=$T/authorized_keys
  # An empty sysfs: whether the wireguard module is there is decided by the modinfo fake.
  export HOMELAB_SYSFS=$T/sys
  unset SSH_CONNECTION
}

# node_env RUNTIME WG_PORT SSH_PORT SERVICES PORTS PUBLIC_PORTS
node_env() {
  printf 'NODE_NAME=vps1\nDOMAIN=homelab.internal\nWG_IP=10.100.10.101\nWG_PORT=%s\nSSH_PORT=%s\nRUNTIME=%s\nOS=debian\nSERVICES="%s"\nPORTS="%s"\nPUBLIC_PORTS="%s"\n' \
    "$2" "$3" "$1" "$4" "$5" "$6" >"$PKG/node/node.env"
  sed -i "s/^ListenPort = .*/ListenPort = $2/" "$PKG/node/wg0.conf" 2>/dev/null || true
}

fake() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/bin/$1" && chmod +x "$T/bin/$1"; }

fakes() {
  fake sshd 'case $1 in -T) echo "port ${FAKE_SSHD_PORT:-22}" ;; esac'
  fake getent '[[ -z ${FAKE_NO_NET:-} ]]'
  fake systemd-detect-virt '[[ -n ${FAKE_CONTAINER:-} ]]'
  # Only `bao status` (step 90); the OpenBao tests replace it with a fuller fake.
  fake docker '[[ $* == *"bao status"* ]] && printf "{\n  \"initialized\": true,\n  \"sealed\": ${FAKE_BAO_SEALED:-false}\n}\n"'
  fake dpkg '[[ $1 == --print-architecture ]] && echo "${FAKE_ARCH:-amd64}"'
  fake modinfo '[[ -z ${FAKE_NO_WG_MODULE:-} ]]'
  fake id '[[ $1 == -u && -n ${FAKE_ADMIN_EXISTS:-} ]] && echo 1000 || exit 1'
  # is-active/is-enabled answer from FAKE_ACTIVE / FAKE_ENABLED (space-separated unit names).
  fake systemctl 'u=${@: -1}; case $1 in is-active) [[ " ${FAKE_ACTIVE:-} " == *" $u "* ]] ;; is-enabled) [[ " ${FAKE_ENABLED:-} " == *" $u "* ]] ;; *) echo "unexpected systemctl $*" >&2; exit 9 ;; esac'
  # latest-handshakes: FAKE_HANDSHAKES "pubkey:age_seconds ..." (age "never" = 0); allowed-ips: FAKE_PEERS "pubkey:ip ...".
  fake wg 'now=$(date +%s); [[ -z ${FAKE_WG_DOWN:-} ]] || exit 1
    case "$3" in
      latest-handshakes) for e in ${FAKE_HANDSHAKES:-}; do a=${e#*:}; [[ $a == never ]] && t=0 || t=$((now - a)); printf "%s\t%s\n" "${e%%:*}" "$t"; done ;;
      allowed-ips) for e in ${FAKE_PEERS:-}; do printf "%s\t%s/32\n" "${e%%:*}" "${e#*:}"; done ;;
      listen-port) echo "${FAKE_WG_LISTEN:-51820}" ;;
    esac'
  fake ufw '[[ $1 == status && -z ${FAKE_UFW_INACTIVE:-} ]] && echo "Status: active"'
  fake curl '[[ -z ${FAKE_NO_METRICS:-} ]] && echo "node_exporter_build_info{version=\"1\"} 1"'
  # k3s kubectl: get --raw (FAKE_K3S_DOWN fails it) and run (prints ok:PORT for FAKE_POD_OK ports).
  fake k3s 'case "$2" in get) [[ -z ${FAKE_K3S_DOWN:-} ]] ;; run) for p in ${FAKE_POD_OK:-}; do echo "ok:$p"; done ;; esac'
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
  [[ $output == *"apt-get install -y chrony fail2ban unattended-upgrades wireguard-tools ufw"* ]]
  [[ $output != *" wireguard "* ]] # the metapackage could pull in another kernel
  [[ $output == *"systemctl enable --now chrony"* ]]
  [[ $output == *"[dry-run] hostnamectl set-hostname vps1"* ]]
  [[ $output == *"[dry-run] timedatectl set-timezone Etc/UTC"* ]]
  [[ $output == *'Unattended-Upgrade::Automatic-Reboot "false";'* ]]
  [[ $output == *"ignoreip = 127.0.0.1/8 ::1 10.100.10.0/24"* ]]
  [[ $output == *"net.ipv4.ip_forward = 1"* ]]
  [[ $output == *"[dry-run] sysctl -p /etc/sysctl.d/90-homelab.conf"* && $output != *"sysctl --system"* ]]
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

# --- 02 WireGuard -------------------------------------------------------------

@test "02: installs wg0.conf (mode 600, content hidden) and enables wg-quick@wg0" {
  step 02-wireguard
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] write /etc/wireguard/wg0.conf (mode 600)"*"(content hidden)"* ]]
  [[ $output != *PrivateKey* ]]
  before 'write /etc/wireguard/wg0.conf' 'systemctl enable --now wg-quick@wg0'
}

@test "02: a running tunnel is updated with syncconf, not restarted" {
  FAKE_ACTIVE=wg-quick@wg0 step 02-wireguard --force
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] bash -c"*syncconf*wg0* ]]
  [[ $output != *"enable --now"* && $output != *restart* ]]
}

@test "02: wg0.conf must listen on WG_PORT from node.env (443)" {
  node_env compose 443 22 "" "" ""
  step 02-wireguard
  [ "$status" -eq 0 ]
  sed -i 's/^ListenPort = .*/ListenPort = 51820/' "$PKG/node/wg0.conf"
  step 02-wireguard
  [ "$status" -eq 1 ]
  [[ $stderr == *"does not listen on WG_PORT=443"* ]]
}

@test "02: peer check only warns: missing handshakes or no interface do not fail the step" {
  FAKE_HANDSHAKES="b:never c:never a:10" step 02-wireguard
  [ "$status" -eq 0 ]
  [[ $stderr == *"2 of 3 WireGuard peers have no handshake yet"* ]]
  FAKE_WG_DOWN=1 step 02-wireguard
  [ "$status" -eq 0 ]
  [[ $stderr == *"wg0 is not up yet"* ]]
}

@test "02: all peers with a handshake" {
  FAKE_HANDSHAKES="a:10 b:20" step 02-wireguard
  [ "$status" -eq 0 ]
  [[ $stderr == *"all 2 WireGuard peers have a handshake"* ]]
}

# --- 03 UFW and 03-ssh --------------------------------------------------------

@test "03: SSH allowed before ufw enable; deny incoming; WG port; service ports only from the WG network" {
  step 03-ufw
  [ "$status" -eq 0 ]
  before 'ufw allow 22/tcp' 'ufw --force enable'
  before 'ufw default deny incoming' 'ufw --force enable'
  [[ $output == *"[dry-run] ufw allow 51820/udp"* ]]
  [[ $output == *"[dry-run] ufw allow from 10.100.10.0/24 to any port 5432 comment homelab-service"* ]] # tcp + udp
  [[ $output == *"[dry-run] ufw allow from 10.100.10.0/24 to any port 22 proto tcp"* ]]
  [[ $output != *"ufw allow 5432"* ]] # never public
}

@test "03: compose machine has no k3s rules" {
  step 03-ufw
  [ "$status" -eq 0 ]
  [[ $output != *10.42.0.0/16* && $output != *10.43.0.0/16* && $output != *6443* ]]
}

@test "03: k3s machine also allows pod and service networks and the API from WireGuard" {
  node_env k3s 51820 22 "" "" ""
  step 03-ufw
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] ufw allow from 10.42.0.0/16"* ]]
  [[ $output == *"[dry-run] ufw allow from 10.43.0.0/16"* ]]
  [[ $output == *"[dry-run] ufw allow from 10.100.10.0/24 to any port 6443 proto tcp"* ]]
  before 'ufw allow from 10.42.0.0/16' 'ufw --force enable'
}

@test "03: PUBLIC_PORTS of the edge are open to everyone" {
  node_env compose 51820 22 "traefik" "" "80 443"
  step 03-ufw
  [[ $output == *"[dry-run] ufw allow 80/tcp"* && $output == *"[dry-run] ufw allow 443/tcp"* ]]
}

@test "03: non-default ports (WG 443, SSH 2222) are used, 51820 and 22 appear nowhere" {
  node_env compose 443 2222 "" "" ""
  step 03-ufw
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] ufw allow 2222/tcp"* && $output == *"[dry-run] ufw allow 443/udp"* ]]
  [[ $output != *51820* ]]
  run grep -E '\b22/tcp|port 22 ' <<<"$output"
  [ "$status" -eq 1 ]
}

@test "03: the current session's port stays allowed while sshd moved (22 -> 2222), all before enable" {
  node_env compose 51820 2222 "" "" ""
  SSH_CONNECTION="203.0.113.5 50000 198.51.100.7 22" step 03-ufw
  [ "$status" -eq 0 ]
  before 'ufw allow 2222/tcp' 'ufw --force enable'
  before 'ufw allow 22/tcp' 'ufw --force enable'
}

@test "03-ssh: no admin handshake -> public SSH stays, no delete, no marker, instructions" {
  FAKE_PEERS="adm:10.100.10.200 m:10.100.10.102" FAKE_HANDSHAKES="adm:never m:5" step 03-ufw
  [ "$status" -eq 0 ]
  [[ $output != *"ufw delete"* && $output != *systemd-run* ]]
  [[ $stderr == *"public SSH stays open"*"sudo ./install.sh --step 03-ssh"* ]]
  [ ! -e "$T/state/done/03-ssh" ]
}

@test "03-ssh: a stale admin handshake (> 120 s) is not enough; a machine peer never counts" {
  FAKE_PEERS="adm:10.100.10.200 m:10.100.10.102" FAKE_HANDSHAKES="adm:300 m:1" step 03-ufw
  [[ $output != *"ufw delete"* ]]
}

@test "03-ssh: fresh admin handshake -> rollback timer before closing; timer left running for the admin" {
  node_env compose 51820 2222 "" "" ""
  FAKE_PEERS="adm:10.100.10.201" FAKE_HANDSHAKES="adm:30" \
    SSH_CONNECTION="203.0.113.5 50000 198.51.100.7 22" step 03-ufw
  [ "$status" -eq 0 ]
  before 'systemd-run --unit homelab-ssh-rollback --on-active=5min ufw allow 2222/tcp' 'ufw delete allow 2222/tcp'
  [[ $output == *"[dry-run] ufw delete allow 22/tcp"* ]] # the old session port too
  [[ $output != *"systemctl stop homelab-ssh-rollback.timer"* ]]
  [[ $stderr == *"sudo systemctl stop homelab-ssh-rollback.timer"* ]]
  run grep -c 'ufw allow from 10.100.10.0/24 to any port 2222 proto tcp' <<<"$output"
  [ "$output" = 1 ]
}

@test "03-ssh: session over WireGuard proves the path; the rollback timer is stopped" {
  mkdir -p "$T/state/done" && touch "$T/state/done/03"
  SSH_CONNECTION="10.100.10.200 50000 10.100.10.101 22" step 03-ufw
  [ "$status" -eq 0 ]
  [[ $output != *"ufw --force enable"* ]] # step 03 itself is done
  before 'systemd-run' 'ufw delete allow 22/tcp'
  before 'ufw delete allow 22/tcp' 'systemctl stop homelab-ssh-rollback.timer'
}

@test "03-ssh: a pending rollback timer stops it" {
  FAKE_ACTIVE=homelab-ssh-rollback.timer SSH_CONNECTION="10.100.10.200 1 10.100.10.101 22" step 03-ufw
  [ "$status" -eq 1 ]
  [[ $stderr == *"homelab-ssh-rollback.timer is still pending"* ]]
}

@test "03: after 03-ssh, re-running 03 with --force does not reopen public SSH" {
  mkdir -p "$T/state/done" && touch "$T/state/done/03-ssh"
  step 03-ufw --force
  [ "$status" -eq 0 ]
  [[ $output != *"ufw allow 22/tcp"* ]]
  [[ $output == *"ufw allow from 10.100.10.0/24 to any port 22 proto tcp"* ]]
}

# --- 04 CA trust --------------------------------------------------------------

@test "04: installs root_ca.crt for update-ca-certificates" {
  step 04-ca-trust
  [ "$status" -eq 0 ]
  before "install -m 644 $PKG/common/root_ca.crt /usr/local/share/ca-certificates/homelab-root-ca.crt" 'update-ca-certificates'
}

@test "04: rejects a file that is not a certificate" {
  echo garbage >"$PKG/common/root_ca.crt"
  step 04-ca-trust
  [ "$status" -eq 1 ]
  [[ $stderr == *"is not a PEM certificate"* ]]
  [[ $output != *update-ca-certificates* ]]
}

@test "04: the package root CA verifies with openssl" {
  openssl verify -CAfile "$PKG/common/root_ca.crt" "$PKG/common/root_ca.crt"
}

# --- input validation: nothing from files, arguments or the environment runs as a command ----

@test "security: node.env values with commands are rejected and never executed" {
  local v
  for v in 'NODE_NAME=$(touch PWNED)' 'NODE_NAME="a;touch PWNED"' 'PORTS="22;touch PWNED"' 'SERVICES="a b|c"'; do
    node_env compose 51820 22 "" "" ""
    sed -i "/^${v%%=*}=/d" "$PKG/node/node.env"
    printf '%s\n' "$v" >>"$PKG/node/node.env"
    cd "$T"
    step 01-base
    [ "$status" -eq 1 ]
    [ ! -e "$T/PWNED" ]
    [[ $output != *apt-get* ]]
  done
}

@test "security: node.env cannot set other variables (PATH) and values are range-checked" {
  echo 'PATH=/tmp/evil' >>"$PKG/node/node.env"
  step 03-ufw
  [ "$status" -eq 1 ]
  [[ $stderr == *"key PATH is not allowed"* ]]
  node_env bogus 70000 0 "" "99999" ""
  sed -i 's/^WG_IP=.*/WG_IP=192.168.1.5/' "$PKG/node/node.env"
  step 03-ufw
  [ "$status" -eq 1 ]
  [[ $stderr == *"RUNTIME must be compose or k3s"* && $stderr == *"WG_PORT must be a port"* ]]
  [[ $stderr == *"SSH_PORT must be a port"* && $stderr == *"PORTS must list ports 1-65535, got: 99999"* ]]
  [[ $stderr == *"WG_IP must be in 10.100.10.0/24"* ]]
  [[ $output != *ufw* ]]
}

@test "security: /etc/os-release is read, not sourced" {
  printf 'ID=$(touch %s/PWNED)\n' "$T" >"$T/os-release"
  step 00-preflight
  [ "$status" -eq 1 ]
  [[ $stderr == *"unsupported system ''"* ]]
  [ ! -e "$T/PWNED" ]
}

@test "security: extra arguments to a step are rejected before anything runs" {
  step 01-base 'touch /tmp/x'
  [ "$status" -eq 1 ]
  [[ $stderr == *"unknown argument: touch /tmp/x"* ]]
  [[ $output != *apt-get* ]]
}

@test "security: admin user name and timezone must be plain values" {
  HOMELAB_ADMIN_USER='a;id' step 01-base
  [ "$status" -eq 1 ]
  [[ $stderr == *"HOMELAB_ADMIN_USER must be a lowercase user name other than root"* ]]
  HOMELAB_ADMIN_USER=root step 01-base
  [ "$status" -eq 1 ]
  HOMELAB_TIMEZONE='../../etc/shadow' step 01-base
  [ "$status" -eq 1 ]
  [[ $stderr == *"HOMELAB_TIMEZONE must look like Region/City"* ]]
  HOMELAB_ADMIN_KEYS='relative/keys' step 01-base
  [ "$status" -eq 1 ]
  [[ $stderr == *"admin keys path must be absolute"* ]]
}

@test "security: a malformed SSH_CONNECTION never reaches ufw" {
  SSH_CONNECTION='1.2.3.4 1 5.6.7.8 22/tcp;id' step 03-ufw
  [ "$status" -eq 0 ]
  [[ $stderr == *"ignoring malformed SSH_CONNECTION"* ]]
  [[ $output != *";id"* ]]
}

@test "security: COMPOSE_SERVICES must be service ids that are also in SERVICES" {
  printf 'COMPOSE_SERVICES="evil"\n' >>"$PKG/node/node.env"
  step 03-ufw
  [ "$status" -eq 1 ]
  [[ $stderr == *"COMPOSE_SERVICES has evil, which is not in SERVICES"* ]]
}

# --- 10 Docker ------------------------------------------------------------------

@test "10: compose machine gets Docker from Docker's repo, key fingerprint checked before apt trusts it" {
  node_env compose 51820 22 "node-exporter postgresql" "9100 5432" ""
  printf 'COMPOSE_SERVICES="node-exporter postgresql"\n' >>"$PKG/node/node.env"
  step 10-docker
  [ "$status" -eq 0 ]
  [[ $output == *'"bip": "172.17.0.1/16"'* ]]
  before 'write /etc/docker/daemon.json' 'apt-get install -y docker-ce'
  before 'curl .*https://download.docker.com/linux/debian/gpg' 'verify gpg fingerprint .* = 9DC858229FC7DD38854AE2D88D81803C0EBFCD88'
  before 'verify gpg fingerprint' 'install -m 644 /etc/apt/keyrings/docker.asc.download /etc/apt/keyrings/docker.asc'
  before 'install -m 644 .*docker.asc' 'write /etc/apt/sources.list.d/docker.list'
  [[ $output == *"deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable"* ]]
  [[ $output == *"docker-compose-plugin"* ]]
  [[ $output != *k3s* ]]
}

@test "10: k3s machine with only k3s services does not install Docker" {
  node_env k3s 51820 22 "node-exporter app-cluster" "9100" ""
  printf 'COMPOSE_SERVICES=""\n' >>"$PKG/node/node.env"
  step 10-docker
  [ "$status" -eq 0 ]
  [[ $output != *docker-ce* && $output != *"[dry-run]"* ]]
  [[ $stderr == *"no service of vps1 runs under Docker, skipping"* ]]
}

@test "10: k3s machine with a compose service (OpenBao) gets Docker" {
  node_env k3s 51820 22 "node-exporter openbao" "9100 8200" ""
  printf 'COMPOSE_SERVICES="openbao"\n' >>"$PKG/node/node.env"
  step 10-docker
  [ "$status" -eq 0 ]
  [[ $output == *docker-ce* ]]
}

@test "10: Ubuntu uses Docker's ubuntu repository; odd codename or arch stops the step" {
  node_env compose 51820 22 "postgresql" "5432" ""
  printf 'COMPOSE_SERVICES="postgresql"\n' >>"$PKG/node/node.env"
  sed -i 's/^OS=.*/OS=ubuntu/' "$PKG/node/node.env"
  printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' >"$T/os-release"
  step 10-docker
  [[ $output == *"https://download.docker.com/linux/ubuntu noble stable"* ]]
  printf 'ID=ubuntu\nVERSION_CODENAME="noble; id"\n' >"$T/os-release"
  step 10-docker
  [ "$status" -eq 1 ]
  [[ $stderr == *"cannot read VERSION_CODENAME"* ]]
  printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' >"$T/os-release"
  FAKE_ARCH='amd64 x' step 10-docker
  [ "$status" -eq 1 ]
  [[ $stderr == *"unexpected dpkg architecture"* ]]
}

# --- 11 k3s ---------------------------------------------------------------------

# k3s_package — the cluster CA files the wizard puts into a k3s machine's package.
k3s_package() {
  local d=$PKG/node/k3s-ca/vps1 f
  mkdir -p "$d/etcd"
  for f in server-ca client-ca request-header-ca etcd/peer-ca etcd/server-ca; do
    echo "$f cert" >"$d/$f.crt"
    echo "$f key" >"$d/$f.key"
  done
  echo key >"$d/service.key"
  node_env k3s 51820 22 "node-exporter app-cluster" "9100" ""
  export HOMELAB_K3S_DATA_DIR=$T/k3s
}

@test "11: cluster CAs and config before k3s is installed; node-ip/advertise-address = WG address" {
  k3s_package
  step 11-k3s
  [ "$status" -eq 0 ]
  before "install -m 600 $PKG/node/k3s-ca/vps1/server-ca.key $T/k3s/server/tls/server-ca.key" 'sh .*k3s-install'
  before "install -m 644 $PKG/node/k3s-ca/vps1/etcd/peer-ca.crt $T/k3s/server/tls/etcd/peer-ca.crt" 'sh .*k3s-install'
  before 'service.key' 'sh .*k3s-install'
  before 'write /etc/rancher/k3s/config.yaml' 'sh .*k3s-install'
  [[ $output == *"[dry-run]   node-ip: 10.100.10.101"* && $output == *"[dry-run]   advertise-address: 10.100.10.101"* ]]
  [[ $output == *"cluster-cidr: 10.42.0.0/16"* && $output == *"service-cidr: 10.43.0.0/16"* ]]
  [[ $output != *traefik* ]]
  [[ $output != *0.0.0.0* ]]
}

@test "11: argocd RBAC manifest goes to the auto-deploy directory before k3s starts" {
  k3s_package
  step 11-k3s
  before "install -m 600 $PKG/common/argocd-rbac.yaml $T/k3s/server/manifests/homelab-argocd-rbac.yaml" 'sh .*k3s-install'
}

@test "11: pinned installer from the k3s tag, checksum verified before it runs" {
  k3s_package
  step 11-k3s
  before 'curl .*https://raw.githubusercontent.com/k3s-io/k3s/v1.36.5%2Bk3s1/install.sh' 'verify sha256'
  before 'verify sha256 .*k3s-install-v1.36.5\+k3s1.sh = 46177d4c' 'INSTALL_K3S_VERSION=v1.36.5\+k3s1 INSTALL_K3S_EXEC=server sh'
  [[ $output != *get.k3s.io* && $output != *"| sh"* ]]
}

@test "11: the edge (.100) disables the k3s Traefik" {
  k3s_package
  sed -i 's/^WG_IP=.*/WG_IP=10.100.10.100/' "$PKG/node/node.env"
  step 11-k3s
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run]   disable:"*"[dry-run]     - traefik"* ]]
}

@test "11: compose machine skips k3s entirely" {
  step 11-k3s
  [ "$status" -eq 0 ]
  [[ $output != *"[dry-run]"* ]]
  [[ $stderr == *"vps1 runs compose, skipping k3s"* ]]
}

@test "11: missing CA in the package stops before anything changes" {
  k3s_package
  rm "$PKG/node/k3s-ca/vps1/client-ca.key"
  step 11-k3s
  [ "$status" -eq 1 ]
  [[ $stderr == *"missing $PKG/node/k3s-ca/vps1/client-ca.key"* ]]
  [[ $output != *"[dry-run]"* ]]
}

@test "11: k3s with other CAs is never overwritten; with the same CAs nothing is copied" {
  k3s_package
  mkdir -p "$T/k3s/server/tls"
  echo other >"$T/k3s/server/tls/server-ca.crt"
  step 11-k3s
  [ "$status" -eq 1 ]
  [[ $stderr == *"k3s already has other CAs"* ]]
  [[ $output != *"install -m 600"* ]]
  cp "$PKG/node/k3s-ca/vps1/server-ca.crt" "$PKG/node/k3s-ca/vps1/client-ca.crt" "$T/k3s/server/tls/"
  step 11-k3s
  [ "$status" -eq 0 ]
  [[ $stderr == *"already uses the cluster CAs"* ]]
  [[ $output != *"server/tls/server-ca.key"* ]]
}

@test "11: data dir override must be an absolute path" {
  k3s_package
  HOMELAB_K3S_DATA_DIR='../x' step 11-k3s
  [ "$status" -eq 1 ]
  [[ $stderr == *"HOMELAB_K3S_DATA_DIR must be an absolute path"* ]]
}

# --- 12 node-exporter (catalog service) ----------------------------------------------

# node_exporter_package — services/node-exporter/ as the wizard renders it (WG_IP substituted).
node_exporter_package() {
  local d=$PKG/node/services/node-exporter f
  node_env compose 51820 22 "node-exporter" "9100" ""
  mkdir -p "$d"
  cp "$REPO_ROOT/catalog/node-exporter/install.sh" "$d/"
  for f in docker-compose.yml node-exporter.yaml; do
    WG_IP=10.100.10.101 PORT_9100=9100 envsubst '${WG_IP} ${PORT_9100}' <"$REPO_ROOT/catalog/node-exporter/$f.tpl" >"$d/$f"
  done
}

service() {
  run --separate-stderr env PATH="$T/bin:$PATH" bash "$PKG/node/services/$1/install.sh" --dry-run "${@:2}"
}

@test "12: node-exporter on a compose machine runs under Docker, listening on the WG address only" {
  node_exporter_package
  printf 'COMPOSE_SERVICES="node-exporter"\n' >>"$PKG/node/node.env"
  service node-exporter
  [ "$status" -eq 0 ]
  [[ $output == *"docker compose -f /opt/homelab/node-exporter/docker-compose.yml up -d"* ]]
  grep -qF -- '--web.listen-address=10.100.10.101:9100' "$PKG/node/services/node-exporter/docker-compose.yml"
  run ! grep -rq '0\.0\.0\.0' "$PKG/node/services/node-exporter"
}

@test "12: node-exporter on a k3s machine is a k3s manifest, no Docker" {
  node_exporter_package
  node_env k3s 51820 22 "node-exporter" "9100" ""
  printf 'COMPOSE_SERVICES=""\n' >>"$PKG/node/node.env"
  HOMELAB_K3S_DATA_DIR=$T/k3s service node-exporter
  [ "$status" -eq 0 ]
  [[ $output == *"install -m 600 $PKG/node/services/node-exporter/node-exporter.yaml $T/k3s/server/manifests/homelab-node-exporter.yaml"* ]]
  [[ $output != *docker* ]]
  grep -qF -- '--web.listen-address=10.100.10.101:9100' "$PKG/node/services/node-exporter/node-exporter.yaml"
}

@test "12: node-exporter refuses to guess on a compose machine without it in COMPOSE_SERVICES" {
  node_exporter_package
  service node-exporter
  [ "$status" -eq 1 ]
  [[ $stderr == *"neither in COMPOSE_SERVICES nor on a k3s machine"* ]]
}

@test "12: node-exporter installer accepts no extra arguments" {
  node_exporter_package
  printf 'COMPOSE_SERVICES="node-exporter"\n' >>"$PKG/node/node.env"
  service node-exporter '$(id)'
  [ "$status" -eq 1 ]
  [[ $output != *docker* ]]
}

# --- container mode (tests/container): kernel-wide actions are skipped with a message ----------

@test "container: 01 skips hostname and sysctl, says so" {
  FAKE_CONTAINER=1 step 01-base
  [ "$status" -eq 0 ]
  [[ $stderr == *"skipped in container: hostname vps1"* && $stderr == *"skipped in container: sysctl"* ]]
  [[ $stderr == *"skipped in container: chrony"* && $output != *"enable --now chrony"* ]]
  [[ $output != *hostnamectl* && $output != *"sysctl -p"* ]]
  [[ $output == *"systemctl reload ssh"* ]] # everything else still runs
}

@test "container: 10 installs Docker packages but does not start dockerd" {
  node_env compose 51820 22 "postgresql" "5432" ""
  printf 'COMPOSE_SERVICES="postgresql"\n' >>"$PKG/node/node.env"
  FAKE_CONTAINER=1 step 10-docker
  [ "$status" -eq 0 ]
  [[ $output == *docker-ce* && $output != *"enable --now docker"* ]]
  [[ $stderr == *"skipped in container: starting dockerd"* ]]
}

@test "container: 11 places CAs and config, verifies the installer, but does not run it" {
  k3s_package
  FAKE_CONTAINER=1 step 11-k3s
  [ "$status" -eq 0 ]
  [[ $output == *"server/tls/server-ca.key"* && $output == *"verify sha256"* ]]
  [[ $output != *INSTALL_K3S_VERSION* ]]
  [[ $stderr == *"skipped in container: running the k3s installer"* ]]
}

@test "container: node-exporter on compose skips docker compose up" {
  node_exporter_package
  printf 'COMPOSE_SERVICES="node-exporter"\n' >>"$PKG/node/node.env"
  FAKE_CONTAINER=1 service node-exporter
  [ "$status" -eq 0 ]
  [[ $output != *"compose -f"* ]]
  [[ $stderr == *"skipped in container: docker compose up for node-exporter"* ]]
}

# --- 90 verification ------------------------------------------------------------------

verify() {
  export HOMELAB_CA_BUNDLE=$PKG/common/root_ca.crt
  step 90-verify
}

@test "90: a working compose machine passes (WG port, sshd port, UFW, CA, node_exporter)" {
  node_env compose 51820 22 "node-exporter" "9100" ""
  FAKE_HANDSHAKES="a:5" verify
  [ "$status" -eq 0 ]
  [[ $stderr == *"verify OK: wg0 listens on 51820/udp"* && $stderr == *"verify OK: sshd on port 22"* ]]
  [[ $stderr == *"verify OK: UFW active"* && $stderr == *"verify OK: homelab root CA trusted"* ]]
  [[ $stderr == *"verify OK: node_exporter on 10.100.10.101:9100"* ]]
  [[ $stderr == *"verification of vps1 passed"* ]]
  [[ $output != *"[dry-run]"* ]] # read-only
}

@test "90: reports every failure and exits 1" {
  node_env compose 443 2222 "node-exporter" "9100" ""
  sed -i 's/^ListenPort = .*/ListenPort = 443/' "$PKG/node/wg0.conf"
  export HOMELAB_CA_BUNDLE=$T/os-release # not a CA bundle
  FAKE_WG_LISTEN=51820 FAKE_UFW_INACTIVE=1 FAKE_NO_METRICS=1 step 90-verify
  [ "$status" -eq 1 ]
  [[ $stderr == *"wg0 listens on 51820, expected 443"* && $stderr == *"sshd on port 22, expected 2222"* ]]
  [[ $stderr == *"UFW is not active"* && $stderr == *"homelab root CA is not in"* ]]
  [[ $stderr == *"node_exporter does not answer"* && $stderr == *"verification of vps1 failed"* ]]
}

@test "90: wg0 down is a failure; peers without handshake only a warning" {
  FAKE_WG_DOWN=1 verify
  [ "$status" -eq 1 ]
  [[ $stderr == *"WireGuard interface wg0 is not up"* ]]
  FAKE_HANDSHAKES="a:never b:3" verify
  [ "$status" -eq 0 ]
  [[ $stderr == *"1 of 2 WireGuard peers without a handshake yet"* ]]
}

@test "90: k3s checks API, CA and pod -> compose service on every port (exact port match)" {
  k3s_package
  node_env k3s 51820 22 "node-exporter openbao" "53 5432" ""
  printf 'COMPOSE_SERVICES="openbao"\n' >>"$PKG/node/node.env"
  mkdir -p "$T/k3s/server/tls" && cp "$PKG/node/k3s-ca/vps1/server-ca.crt" "$T/k3s/server/tls/"
  FAKE_POD_OK="5432" verify
  [ "$status" -eq 1 ]
  [[ $stderr == *"verify OK: k3s API ready"* && $stderr == *"k3s uses the cluster CA from the wizard"* ]]
  [[ $stderr == *"verify OK: pod -> 10.100.10.101:5432"* ]]
  [[ $stderr == *"pod cannot reach 10.100.10.101:53"* ]] # ok:5432 must not count for 53
  FAKE_POD_OK="53 5432" verify
  [ "$status" -eq 0 ]
}

@test "90: k3s with a foreign CA or a dead API fails" {
  k3s_package
  mkdir -p "$T/k3s/server/tls" && echo other >"$T/k3s/server/tls/server-ca.crt"
  verify
  [ "$status" -eq 1 ]
  [[ $stderr == *"k3s server CA differs from the package"* ]]
  FAKE_K3S_DOWN=1 verify
  [[ $stderr == *"k3s API is not ready"* ]]
}

@test "90: in a container k3s and node_exporter checks are skipped with a message" {
  k3s_package
  FAKE_CONTAINER=1 verify
  [ "$status" -eq 0 ]
  [[ $stderr == *"skipped in container: k3s checks"* && $stderr == *"skipped in container: node_exporter check"* ]]
}

@test "90: CA bundle override must be an absolute path" {
  HOMELAB_CA_BUNDLE='x/../y' step 90-verify
  [ "$status" -eq 1 ]
  [[ $stderr == *"HOMELAB_CA_BUNDLE must be an absolute path"* ]]
}

@test "00: an already loaded wireguard module (sysfs, as in a container) is enough" {
  mkdir -p "$T/sys/module/wireguard"
  FAKE_NO_WG_MODULE=1 step 00-preflight
  [ "$status" -eq 0 ]
}

# --- 20 coredns, 21 step-ca (catalog services) ----------------------------------------

# service_package ID FILE... — services/ID/ with the catalog installer and rendered FILEs.
service_package() {
  local id=$1 f
  shift
  mkdir -p "$PKG/node/services/$id"
  cp "$REPO_ROOT/catalog/$id/install.sh" "$PKG/node/services/$id/"
  for f in "$@"; do echo "rendered $f" >"$PKG/node/services/$id/$f"; done
}

@test "20: coredns installs its files and starts under Docker; refuses to run outside compose" {
  service_package coredns docker-compose.yml Corefile db.homelab.internal
  node_env compose 51820 22 "coredns" "53" ""
  printf 'COMPOSE_SERVICES="coredns"\n' >>"$PKG/node/node.env"
  service coredns
  [ "$status" -eq 0 ]
  [[ $output == *"install -m 644 $PKG/node/services/coredns/db.homelab.internal /opt/homelab/coredns/db.homelab.internal"* ]]
  before 'opt/homelab/coredns/Corefile' 'docker compose -f /opt/homelab/coredns/docker-compose.yml up -d --force-recreate'
  sed -i 's/^COMPOSE_SERVICES=.*/COMPOSE_SERVICES=""/' "$PKG/node/node.env"
  node_env k3s 51820 22 "coredns" "53" ""
  printf 'COMPOSE_SERVICES=""\n' >>"$PKG/node/node.env"
  service coredns
  [ "$status" -eq 1 ]
  [[ $stderr == *"coredns runs only under Docker"* ]]
}

@test "20: coredns needs the generated zone in the package" {
  service_package coredns docker-compose.yml Corefile
  node_env compose 51820 22 "coredns" "53" ""
  printf 'COMPOSE_SERVICES="coredns"\n' >>"$PKG/node/node.env"
  service coredns
  [ "$status" -eq 1 ]
  [[ $stderr == *"missing $PKG/node/services/coredns/db.homelab.internal"* ]]
}

# step_ca_package — what the wizard gives the step-ca machine: intermediate CA and the secret.
step_ca_package() {
  service_package step-ca docker-compose.yml ca.json
  mkdir -p "$PKG/node/ca"
  echo crt >"$PKG/node/ca/intermediate_ca.crt"
  echo key >"$PKG/node/ca/intermediate_ca.key"
  printf 'STEP_CA_DEFAULT_USERNAME=app\nSTEP_CA_DEFAULT_PASSWORD=s3cret-pass\nOTHER_ROOT_PASSWORD=x\n' >"$PKG/node/secrets.env"
  chmod 600 "$PKG/node/secrets.env"
  node_env compose 51820 22 "step-ca" "9000" ""
  printf 'COMPOSE_SERVICES="step-ca"\n' >>"$PKG/node/node.env"
}

@test "21: step-ca gets the intermediate (key 600, owned by the step user) and the JWK password hidden" {
  step_ca_package
  service step-ca
  [ "$status" -eq 0 ]
  [[ $output == *"install -m 600 -o 1000 -g 1000 $PKG/node/ca/intermediate_ca.key /opt/homelab/step-ca/step/secrets/intermediate_ca.key"* ]]
  [[ $output == *"$PKG/common/root_ca.crt /opt/homelab/step-ca/step/certs/root_ca.crt"* ]]
  [[ $output == *"write /opt/homelab/step-ca/step/secrets/provisioner_password (mode 600)"*"(content hidden)"* ]]
  [[ $output != *s3cret-pass* ]]
  before 'config/ca.json' 'ca provisioner add app --type JWK --create'
  before 'ca provisioner add' 'up -d --force-recreate'
}

@test "21: step-ca without the intermediate CA (another machine's package) stops" {
  step_ca_package
  rm "$PKG/node/ca/intermediate_ca.key"
  service step-ca
  [ "$status" -eq 1 ]
  [[ $stderr == *"only the step-ca machine's package has the intermediate CA"* ]]
  [[ $output != *"[dry-run]"* ]]
}

@test "21: step-ca rejects a secrets.env with commands or a bad provisioner name" {
  step_ca_package
  printf 'STEP_CA_DEFAULT_USERNAME=app\nSTEP_CA_DEFAULT_PASSWORD=$(touch %s/PWNED)\n' "$T" >"$PKG/node/secrets.env"
  service step-ca
  [ "$status" -eq 1 ]
  [ ! -e "$T/PWNED" ]
  printf 'STEP_CA_DEFAULT_USERNAME="a b"\nSTEP_CA_DEFAULT_PASSWORD=x\n' >"$PKG/node/secrets.env"
  service step-ca
  [ "$status" -eq 1 ]
}

@test "21: in a container step-ca is configured but not started" {
  step_ca_package
  FAKE_CONTAINER=1 service step-ca
  [ "$status" -eq 0 ]
  [[ $output == *"intermediate_ca.key"* && $output != *"provisioner add"* ]]
  [[ $stderr == *"skipped in container: adding the JWK provisioner and starting step-ca"* ]]
}

@test "security: node.env DOMAIN must be a domain name" {
  sed -i 's/^DOMAIN=.*/DOMAIN="x;id"/' "$PKG/node/node.env"
  step 03-ufw
  [ "$status" -eq 1 ]
  [[ $stderr == *"DOMAIN must be a domain name"* ]]
}

# --- 40 traefik (catalog service) ---------------------------------------------------

traefik_package() {
  service_package traefik docker-compose.yml
  mkdir -p "$PKG/node/services/traefik/dynamic"
  echo 'http: {}' >"$PKG/node/services/traefik/dynamic/routes.yml"
  printf 'certificatesResolvers:\n  acme:\n    acme:\n      caServer: "https://10.100.10.101:9000/acme/acme/directory"\n' \
    >"$PKG/node/services/traefik/traefik.yml"
  node_env compose 51820 22 "traefik" "" "80 443"
  printf 'COMPOSE_SERVICES="traefik"\n' >>"$PKG/node/node.env"
}

@test "40: traefik installs config, routes and root CA; a new acme.json is created with mode 600" {
  traefik_package
  service traefik
  [ "$status" -eq 0 ]
  [[ $output == *"install -m 644 $PKG/node/services/traefik/dynamic/routes.yml /opt/homelab/traefik/dynamic/routes.yml"* ]]
  [[ $output == *"install -m 644 $PKG/common/root_ca.crt /opt/homelab/traefik/root_ca.crt"* ]]
  before 'install -m 600 /dev/null /opt/homelab/traefik/acme/acme.json' 'up -d --force-recreate'
}

@test "40: traefik without a step-ca address stops before anything changes" {
  traefik_package
  echo 'certificatesResolvers: {}' >"$PKG/node/services/traefik/traefik.yml"
  service traefik
  [ "$status" -eq 1 ]
  [[ $stderr == *"traefik.yml has no step-ca address"* ]]
  [[ $output != *"[dry-run]"* ]]
}

# --- 30 postgresql, 39 postgres-exporter (catalog services) --------------------------

@test "30: postgresql copies compose, the env file (600) and the init script, creates the data dir" {
  service_package postgresql docker-compose.yml postgresql.env
  mkdir -p "$PKG/node/services/postgresql/initdb" && echo x >"$PKG/node/services/postgresql/initdb/10-homelab-accounts.sh"
  node_env compose 51820 22 "postgresql" "5432" ""
  printf 'COMPOSE_SERVICES="postgresql"\n' >>"$PKG/node/node.env"
  service postgresql
  [ "$status" -eq 0 ]
  [[ $output == *"install -D -m 600 $PKG/node/services/postgresql/postgresql.env /opt/homelab/postgresql/postgresql.env"* ]]
  [[ $output == *"install -D -m 644 $PKG/node/services/postgresql/initdb/10-homelab-accounts.sh"* ]]
  before 'install -d -m 700 /var/lib/homelab/data/postgresql' 'docker compose -f /opt/homelab/postgresql/docker-compose.yml up -d'
}

@test "30: postgresql stops before changes when a package file is missing" {
  service_package postgresql docker-compose.yml
  node_env compose 51820 22 "postgresql" "5432" ""
  printf 'COMPOSE_SERVICES="postgresql"\n' >>"$PKG/node/node.env"
  service postgresql
  [ "$status" -eq 1 ]
  [[ $stderr == *"missing $PKG/node/services/postgresql/postgresql.env"* ]]
  [[ $output != *"[dry-run]"* ]]
}

@test "39: postgres-exporter installs its env file (600) and starts" {
  service_package postgres-exporter docker-compose.yml postgres-exporter.env
  node_env compose 51820 22 "postgresql postgres-exporter" "5432 9187" ""
  printf 'COMPOSE_SERVICES="postgresql postgres-exporter"\n' >>"$PKG/node/node.env"
  service postgres-exporter
  [ "$status" -eq 0 ]
  [[ $output == *"install -D -m 600 $PKG/node/services/postgres-exporter/postgres-exporter.env"* ]]
  [[ $output == *"docker compose -f /opt/homelab/postgres-exporter/docker-compose.yml up -d"* ]]
}

@test "postgresql init script: names and passwords go to psql as variables, never into the SQL" {
  local evil="x'; DROP DATABASE postgres; --"
  fake psql 'printf "%s\n" "$@" >"'"$T"'/psql.args"; cat >"'"$T"'/psql.sql"'
  run env PATH="$T/bin:$PATH" POSTGRES_USER=root POSTGRESQL_DEFAULT_USERNAME=app POSTGRESQL_DEFAULT_PASSWORD="$evil" \
    POSTGRESQL_VIEWER_USERNAME=viewer POSTGRESQL_VIEWER_PASSWORD=v bash "$REPO_ROOT/catalog/postgresql/initdb/10-homelab-accounts.sh"
  [ "$status" -eq 0 ]
  grep -qxF -- "--set=app_pass=$evil" "$T/psql.args"
  run ! grep -qF 'DROP' "$T/psql.sql"
  grep -qxF "CREATE ROLE :\"app_user\" LOGIN PASSWORD :'app_pass';" "$T/psql.sql"
  grep -qxF 'GRANT pg_monitor, pg_read_all_data TO :"viewer_user";' "$T/psql.sql"
}

# --- 31 mariadb, 39 mysqld-exporter (catalog services) ---------------------------------

@test "31: mariadb copies compose, the env file (600) and the init script, creates the data dir" {
  service_package mariadb docker-compose.yml mariadb.env
  mkdir -p "$PKG/node/services/mariadb/initdb" && echo x >"$PKG/node/services/mariadb/initdb/10-homelab-viewer.sh"
  node_env compose 51820 22 "mariadb" "3306" ""
  printf 'COMPOSE_SERVICES="mariadb"\n' >>"$PKG/node/node.env"
  service mariadb
  [ "$status" -eq 0 ]
  [[ $output == *"install -D -m 600 $PKG/node/services/mariadb/mariadb.env /opt/homelab/mariadb/mariadb.env"* ]]
  # 644: the entrypoint sources the init script (no exec bit), so it can use docker_process_sql.
  [[ $output == *"install -D -m 644 $PKG/node/services/mariadb/initdb/10-homelab-viewer.sh"* ]]
  before 'install -d -m 700 /var/lib/homelab/data/mariadb' 'docker compose -f /opt/homelab/mariadb/docker-compose.yml up -d'
}

@test "39: mysqld-exporter installs its env file (600) and starts" {
  service_package mysqld-exporter docker-compose.yml mysqld-exporter.env
  node_env compose 51820 22 "mariadb mysqld-exporter" "3306 9104" ""
  printf 'COMPOSE_SERVICES="mariadb mysqld-exporter"\n' >>"$PKG/node/node.env"
  service mysqld-exporter
  [ "$status" -eq 0 ]
  [[ $output == *"install -D -m 600 $PKG/node/services/mysqld-exporter/mysqld-exporter.env"* ]]
}

# mariadb_init — sources the init script as the entrypoint does, with docker_process_sql recording SQL.
mariadb_init() {
  run env MARIADB_VIEWER_USERNAME="$1" MARIADB_VIEWER_PASSWORD="$2" bash -c '
    docker_process_sql() { cat >"'"$T"'/mariadb.sql"; }
    source "$REPO_ROOT/catalog/mariadb/initdb/10-homelab-viewer.sh"'
}

@test "mariadb init script: creates the VIEWER with exporter grants" {
  mariadb_init viewer s3cret-pass
  [ "$status" -eq 0 ]
  grep -qF "CREATE USER 'viewer'@'%' IDENTIFIED BY 's3cret-pass'" "$T/mariadb.sql"
  grep -qF "GRANT SELECT, PROCESS, REPLICATION CLIENT, SLAVE MONITOR ON *.* TO 'viewer'@'%';" "$T/mariadb.sql"
}

@test "mariadb init script: a name or password that could change the SQL stops it" {
  local bad
  for bad in "x'; DROP DATABASE mysql; --" 'a b' 'p$x'; do
    mariadb_init viewer "$bad"
    [ "$status" -eq 1 ]
    [[ $output == *"unexpected characters"* ]]
  done
  mariadb_init "viewer'@'%" pass
  [ "$status" -eq 1 ]
  [ ! -e "$T/mariadb.sql" ]
}

# --- 33 valkey, 39 redis-exporter (catalog services) -----------------------------------

valkey_package() {
  service_package valkey docker-compose.yml valkey.conf
  printf 'user default off\nuser app on #abc ~* &* +@all -@admin\n' >"$PKG/node/services/valkey/users.acl"
  node_env compose 51820 22 "valkey" "6379" ""
  printf 'COMPOSE_SERVICES="valkey"\n' >>"$PKG/node/node.env"
}

@test "33: valkey installs config and ACL (600, owned by the valkey user), data dir, then starts" {
  valkey_package
  service valkey
  [ "$status" -eq 0 ]
  before 'install -D -m 600 .*/users.acl /opt/homelab/valkey/users.acl' 'chown 999:999 /opt/homelab/valkey/users.acl'
  before 'chown 999:999 /opt/homelab/valkey/users.acl' 'docker compose -f /opt/homelab/valkey/docker-compose.yml up -d'
  [[ $output == *"install -d -m 700 /var/lib/homelab/data/valkey"* ]]
}

@test "33: valkey refuses an ACL file where the default user is not off" {
  valkey_package
  printf 'user default on nopass ~* +@all\n' >"$PKG/node/services/valkey/users.acl"
  service valkey
  [ "$status" -eq 1 ]
  [[ $stderr == *"the default user is not off"* ]]
  [[ $output != *"[dry-run]"* ]]
}

@test "39: redis-exporter installs its env file (600) and starts" {
  service_package redis-exporter docker-compose.yml redis-exporter.env
  node_env compose 51820 22 "valkey redis-exporter" "6379 9121" ""
  printf 'COMPOSE_SERVICES="valkey redis-exporter"\n' >>"$PKG/node/node.env"
  service redis-exporter
  [ "$status" -eq 0 ]
  [[ $output == *"install -D -m 600 $PKG/node/services/redis-exporter/redis-exporter.env"* ]]
}

# --- 32 rustfs (catalog service) ------------------------------------------------------

@test "32: rustfs installs its env file (600) and data/logs dirs owned by the rustfs user before starting" {
  service_package rustfs docker-compose.yml rustfs.env
  node_env compose 51820 22 "rustfs" "9000 9001" ""
  printf 'COMPOSE_SERVICES="rustfs"\n' >>"$PKG/node/node.env"
  service rustfs
  [ "$status" -eq 0 ]
  [[ $output == *"install -D -m 600 $PKG/node/services/rustfs/rustfs.env /opt/homelab/rustfs/rustfs.env"* ]]
  before 'install -d -m 700 -o 10001 -g 10001 /var/lib/homelab/data/rustfs /var/lib/homelab/data/rustfs/data /var/lib/homelab/data/rustfs/logs' \
    'docker compose -f /opt/homelab/rustfs/docker-compose.yml up -d'
}

@test "32: rustfs runs only under Docker" {
  service_package rustfs docker-compose.yml rustfs.env
  node_env k3s 51820 22 "rustfs" "9000 9001" ""
  printf 'COMPOSE_SERVICES=""\n' >>"$PKG/node/node.env"
  service rustfs
  [ "$status" -eq 1 ]
  [[ $stderr == *"rustfs runs only under Docker"* ]]
}

# --- moved ports in node.env ---------------------------------------------------------

@test "ports: step 90 checks node_exporter on its moved port" {
  node_env compose 51820 22 "node-exporter" "9110" ""
  printf 'PORT_OVERRIDES="node-exporter:9100=9110"\n' >>"$PKG/node/node.env"
  fake curl '[[ $* == *":9110/metrics"* ]] && echo "node_exporter_build_info 1"'
  FAKE_HANDSHAKES="a:5" verify
  [ "$status" -eq 0 ]
  [[ $stderr == *"verify OK: node_exporter on 10.100.10.101:9110"* ]]
}

@test "security: PORT_OVERRIDES must be service:port=port with valid ports" {
  local bad
  for bad in 'x:1=2;id' 'a:70000=1' 'a:1=$(id)'; do
    node_env compose 51820 22 "" "" ""
    printf 'PORT_OVERRIDES="%s"\n' "$bad" >>"$PKG/node/node.env"
    step 03-ufw
    [ "$status" -eq 1 ]
    [[ $output != *ufw* ]]
  done
}

# --- 34 redpanda (catalog service) ------------------------------------------------------

redpanda_package() {
  service_package redpanda docker-compose.yml redpanda.env redpanda.yaml
  printf 'enable_sasl: true\nsuperusers:\n  - root\n' >"$PKG/node/services/redpanda/bootstrap.yaml"
  node_env compose 51820 22 "redpanda" "8081 9092 9644" ""
  printf 'COMPOSE_SERVICES="redpanda"\n' >>"$PKG/node/node.env"
}

@test "34: redpanda installs env (600), node config and .bootstrap.yaml owned by the redpanda user" {
  redpanda_package
  service redpanda
  [ "$status" -eq 0 ]
  [[ $output == *"install -D -m 600 $PKG/node/services/redpanda/redpanda.env /opt/homelab/redpanda/redpanda.env"* ]]
  [[ $output == *"install -d -m 700 -o 101 -g 101 /opt/homelab/redpanda/config /var/lib/homelab/data/redpanda"* ]]
  before "install -m 644 -o 101 -g 101 $PKG/node/services/redpanda/bootstrap.yaml /opt/homelab/redpanda/config/.bootstrap.yaml" \
    'docker compose -f /opt/homelab/redpanda/docker-compose.yml up -d'
  [[ $stderr == *"Kafka API on 10.100.10.101:9092 (SASL/SCRAM-SHA-256)"* ]]
}

@test "34: redpanda refuses a bootstrap file without SASL" {
  redpanda_package
  printf 'superusers:\n  - root\n' >"$PKG/node/services/redpanda/bootstrap.yaml"
  service redpanda
  [ "$status" -eq 1 ]
  [[ $stderr == *"without SASL"* ]]
  [[ $output != *"[dry-run]"* ]]
}

# --- 35 typesense (catalog service) -----------------------------------------------------

@test "35: typesense installs its env file (600) and a data dir owned by the unprivileged user" {
  service_package typesense docker-compose.yml typesense.env
  node_env compose 51820 22 "typesense" "8108" ""
  printf 'COMPOSE_SERVICES="typesense"\n' >>"$PKG/node/node.env"
  service typesense
  [ "$status" -eq 0 ]
  [[ $output == *"install -D -m 600 $PKG/node/services/typesense/typesense.env /opt/homelab/typesense/typesense.env"* ]]
  before 'install -d -m 700 -o 10000 -g 10000 /var/lib/homelab/data/typesense' \
    'docker compose -f /opt/homelab/typesense/docker-compose.yml up -d'
}

# --- 45 openbao (catalog service) -------------------------------------------------------

# openbao_package — services/openbao/ as rendered for the OpenBao machine, and a fake docker that
# answers `bao status` per FAKE_BAO (uninit|sealed|unsealed|down) and records stdin of other calls.
openbao_package() {
  local d=$PKG/node/services/openbao f
  mkdir -p "$d/kv"
  cp "$REPO_ROOT"/catalog/openbao/{install.sh,homelab-openbao-unseal.sh,homelab-openbao-unseal.service,eso-read.hcl} "$d/"
  printf 'OPENBAO_ESO_USERNAME=eso\nOPENBAO_ESO_PASSWORD=EsoTokenId1234567890\n' >"$PKG/node/secrets.env"
  chmod 600 "$PKG/node/secrets.env"
  echo x >"$d/docker-compose.yml" && echo x >"$d/config.hcl"
  echo '{"ROOT_USERNAME": "root", "ROOT_PASSWORD": "pg-secret-value"}' >"$d/kv/postgresql.json"
  echo '{"DEFAULT_USERNAME": "app", "DEFAULT_PASSWORD": "valkey-secret"}' >"$d/kv/valkey.json"
  node_env compose 51820 22 "openbao" "8200" ""
  printf 'COMPOSE_SERVICES="openbao"\n' >>"$PKG/node/node.env"
  fake docker 'case "$*" in
    *"bao status -format=json"*)
      case ${FAKE_BAO:-down} in
        uninit) printf "{\n  \"initialized\": false,\n  \"sealed\": true\n}\n"; exit 2 ;;
        sealed) printf "{\n  \"initialized\": true,\n  \"sealed\": true\n}\n"; exit 2 ;;
        unsealed) printf "{\n  \"initialized\": true,\n  \"sealed\": false\n}\n" ;;
        *) exit 1 ;;
      esac ;;
    *"bao secrets list"*) [[ -n ${FAKE_BAO_KV:-} ]] && echo "{\"homelab/\": {}}" ;;
    *) printf "%s\n" "$*" >>"'"$T"'/docker.args"; cat >>"'"$T"'/docker.stdin" ;;
  esac'
}

# openbao_initialized — the init file the first install left on the machine.
openbao_initialized() {
  mkdir -p "$T/state/openbao"
  printf '{\n  "unseal_keys_b64": [\n    "dW5zZWFsLWtleS0xMjM0NTY3ODkwYWJjZGVm"\n  ],\n  "root_token": "s.RootTokenValue123"\n}\n' \
    >"$T/state/openbao/init.json"
}

@test "45: not initialized -> operator init, then unseal, then the secrets are loaded" {
  openbao_package
  FAKE_BAO=uninit service openbao
  [ "$status" -eq 0 ]
  before 'bao operator init -key-shares=1 -key-threshold=1 -format=json > .*/openbao/init.json \(mode 600\)' 'unseal with the key'
  [[ $output == *"load postgresql.json valkey.json"* ]]
  before 'unseal with the key' 'install -m 644 .*homelab-openbao-unseal.service /etc/systemd/system/'
  [[ $output == *"systemctl enable homelab-openbao-unseal.service"* ]]
}

@test "45: already initialized -> never operator init; unseal and kv put get secrets on stdin only" {
  openbao_package
  openbao_initialized
  FAKE_BAO=sealed service openbao
  [ "$status" -eq 0 ]
  [[ $output != *"operator init"* ]]
  [[ $stderr == *"OpenBao already initialized"* ]]
  before 'bao write -format=json sys/unseal -' 'bao secrets enable -path=homelab kv-v2'
  [[ $output == *"bao kv put -mount=homelab postgresql -"* && $output == *"bao kv put -mount=homelab valkey -"* ]]
  # The key, the token and the secret values never appear in the output or in a command line.
  [[ $output != *dW5zZWFs* && $output != *RootTokenValue* && $output != *pg-secret-value* ]]
  [[ $stderr != *dW5zZWFs* && $stderr != *RootTokenValue* ]]
}

@test "45: an existing KV mount is not enabled again; an unsealed store is not unsealed again" {
  openbao_package
  openbao_initialized
  FAKE_BAO=unsealed FAKE_BAO_KV=1 service openbao
  [ "$status" -eq 0 ]
  [[ $output != *"sys/unseal"* && $output != *"secrets enable"* ]]
  [[ $output == *"bao kv put -mount=homelab postgresql -"* ]]
}

@test "45: initialized without the init file stops (the key would be lost); never re-initializes" {
  openbao_package
  FAKE_BAO=sealed service openbao
  [ "$status" -eq 1 ]
  [[ $stderr == *"is initialized but"*"init.json is missing"*"never initialize again"* ]]
  [[ $output != *"operator init"* ]]
}

@test "45: not initialized while an init file exists (data lost?) stops instead of a new init" {
  openbao_package
  openbao_initialized
  FAKE_BAO=uninit service openbao
  [ "$status" -eq 1 ]
  [[ $stderr == *"is not initialized but"*"init.json exists"* ]]
  [[ $output != *"operator init"* ]]
}

@test "45: a package without kv/ (another machine) stops before anything changes" {
  openbao_package
  rm -r "$PKG/node/services/openbao/kv"
  service openbao
  [ "$status" -eq 1 ]
  [[ $stderr == *"only the OpenBao machine's package has the secrets"* ]]
  [[ $output != *"[dry-run]"* ]]
}

@test "45: in a container OpenBao is configured but not initialized" {
  openbao_package
  FAKE_CONTAINER=1 FAKE_BAO=uninit service openbao
  [ "$status" -eq 0 ]
  [[ $output != *"operator init"* ]]
  [[ $stderr == *"skipped in container: init, unseal and loading secrets"* ]]
}

@test "unseal unit script: unseals a sealed store with the key on stdin, never as an argument" {
  openbao_package
  openbao_initialized
  run env PATH="$T/bin:$PATH" HOMELAB_STATE_DIR="$T/state" FAKE_BAO=sealed bash "$REPO_ROOT/catalog/openbao/homelab-openbao-unseal.sh"
  # The fake stays sealed, so the script reports it; what matters is how the key was passed.
  [[ $output == *"still sealed after unseal"* ]]
  grep -qx 'exec -i homelab-openbao bao write -format=json sys/unseal -' "$T/docker.args"
  grep -qF '{"key":"dW5zZWFsLWtleS0xMjM0NTY3ODkwYWJjZGVm"}' "$T/docker.stdin"
  run ! grep -q dW5zZWFs "$T/docker.args"
}

@test "unseal unit script: nothing to do when unsealed; fails without the init file" {
  openbao_package
  openbao_initialized
  run env PATH="$T/bin:$PATH" HOMELAB_STATE_DIR="$T/state" FAKE_BAO=unsealed bash "$REPO_ROOT/catalog/openbao/homelab-openbao-unseal.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"already unsealed"* ]]
  rm "$T/state/openbao/init.json"
  run env PATH="$T/bin:$PATH" HOMELAB_STATE_DIR="$T/state" bash "$REPO_ROOT/catalog/openbao/homelab-openbao-unseal.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"nothing to unseal with"* ]]
}

@test "90: a sealed OpenBao fails the verification" {
  node_env compose 51820 22 "openbao" "8200" ""
  FAKE_BAO_SEALED=true verify
  [ "$status" -eq 1 ]
  [[ $stderr == *"OpenBao is sealed or not running"* ]]
  verify
  [ "$status" -eq 0 ]
  [[ $stderr == *"verify OK: OpenBao unsealed"* ]]
}

# --- 50 argocd, 60 app-cluster (catalog services) --------------------------------------

argocd_package() {
  local d=$PKG/node/services/argocd f
  mkdir -p "$d/manifests" "$d/store" "$d/clusters"
  cp "$REPO_ROOT/catalog/argocd/install.sh" "$d/"
  for f in 00-namespaces 10-argocd-admin 15-argocd-config 20-repo 30-openbao-token 40-external-secrets-app 50-root-app; do
    echo "kind: x" >"$d/manifests/$f.yaml"
  done
  printf '    - host: "argo.homelab.internal"\n' >"$d/manifests/60-ingress.yaml"
  mkdir -p "$d/k3s" && echo 'kind: x' >"$d/k3s/traefik-acme.yaml"
  echo 'kind: x' >"$d/clusters/vps3.yaml"
  printf 'spec:\n  provider:\n    vault:\n      server: "http://10.100.10.101:8200"\n' >"$d/store/cluster-secret-store.yaml"
  node_env k3s 51820 22 "argocd" "" ""
  printf 'COMPOSE_SERVICES=""\n' >>"$PKG/node/node.env"
}

@test "50: argocd fetches the pinned manifest, checks it, applies namespaces -> ArgoCD -> ours -> clusters -> store" {
  argocd_package
  service argocd
  [ "$status" -eq 0 ]
  before 'curl .*https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml' 'verify sha256 .* = 846c644b'
  before 'verify sha256' 'k3s kubectl apply -f .*/manifests/00-namespaces.yaml'
  before '00-namespaces.yaml' 'kubectl apply --server-side --force-conflicts -n argocd -f .*argocd-install-v3.5.6.yaml'
  before 'argocd-install-v3.5.6.yaml' 'kubectl apply --server-side --force-conflicts -f .*/services/argocd/manifests/'
  before 'services/argocd/manifests/' 'kubectl apply -f .*/services/argocd/clusters/'
  before 'services/argocd/clusters/' 'kubectl apply -f .*/store/cluster-secret-store.yaml'
  [[ $stderr == *"would wait for CRD clustersecretstores.external-secrets.io"* ]]
}

@test "50: argocd needs k3s, its package files and an OpenBao address" {
  argocd_package
  rm "$PKG/node/services/argocd/manifests/20-repo.yaml"
  service argocd
  [ "$status" -eq 1 ]
  [[ $stderr == *"missing $PKG/node/services/argocd/manifests/20-repo.yaml"* ]]
  argocd_package
  echo 'server: ""' >"$PKG/node/services/argocd/store/cluster-secret-store.yaml"
  service argocd
  [ "$status" -eq 1 ]
  [[ $stderr == *"no OpenBao address"* ]]
  argocd_package
  sed -i 's/^RUNTIME=.*/RUNTIME=compose/' "$PKG/node/node.env"
  sed -i 's/^COMPOSE_SERVICES=.*/COMPOSE_SERVICES="argocd"/' "$PKG/node/node.env"
  service argocd
  [ "$status" -eq 1 ]
  [[ $stderr == *"argocd runs only in k3s"* ]]
}

@test "50: in a container ArgoCD is not installed" {
  argocd_package
  FAKE_CONTAINER=1 service argocd
  [ "$status" -eq 0 ]
  [[ $output != *"kubectl apply"* ]]
  [[ $stderr == *"skipped in container: installing ArgoCD"* ]]
}

@test "60: app-cluster only checks the cluster (k3s only)" {
  service_package app-cluster
  node_env k3s 51820 22 "app-cluster" "" ""
  printf 'COMPOSE_SERVICES=""\n' >>"$PKG/node/node.env"
  service app-cluster
  [ "$status" -eq 0 ]
  [[ $stderr == *"would check the k3s API and the homelab-argocd binding"* ]]
  [[ $output != *"[dry-run]"* ]]
  node_env compose 51820 22 "app-cluster" "" ""
  printf 'COMPOSE_SERVICES=""\n' >>"$PKG/node/node.env"
  service app-cluster
  [ "$status" -eq 1 ]
}

@test "45: OpenBao creates the read-only External Secrets token with the wizard's ID, on stdin" {
  openbao_package
  openbao_initialized
  cp "$REPO_ROOT/catalog/openbao/eso-read.hcl" "$PKG/node/services/openbao/"
  printf 'OPENBAO_ESO_USERNAME=eso\nOPENBAO_ESO_PASSWORD=EsoTokenId1234567890\nOPENBAO_ROOT_USERNAME=root\nOPENBAO_ROOT_PASSWORD=r\n' \
    >"$PKG/node/secrets.env"
  chmod 600 "$PKG/node/secrets.env"
  FAKE_BAO=unsealed FAKE_BAO_KV=1 service openbao
  [ "$status" -eq 0 ]
  before 'bao policy write eso-read -' 'bao write sys/auth/token/tune max_lease_ttl=87600h'
  before 'max_lease_ttl=87600h' 'bao write auth/token/create-orphan -'
  [[ $output != *EsoTokenId1234567890* && $stderr != *EsoTokenId1234567890* ]]
}

@test "03: k3s machines open the ingress (80/443) to the WireGuard network only" {
  node_env k3s 51820 22 "" "" ""
  step 03-ufw
  [ "$status" -eq 0 ]
  [[ $output == *"[dry-run] ufw allow from 10.100.10.0/24 to any port 80 proto tcp comment homelab-k3s-ingress"* ]]
  [[ $output == *"[dry-run] ufw allow from 10.100.10.0/24 to any port 443 proto tcp comment homelab-k3s-ingress"* ]]
  [[ $output != *"ufw allow 80/tcp"* && $output != *"ufw allow 443/tcp"* ]]
  node_env compose 51820 22 "" "" ""
  step 03-ufw
  [[ $output != *homelab-k3s-ingress* ]]
}

@test "50: argocd configures the k3s Traefik (root CA, step-ca resolver) first and restarts argocd-server after its config" {
  argocd_package
  echo 'kind: x' >"$PKG/node/services/argocd/manifests/15-argocd-config.yaml"
  printf '    - host: "argo.homelab.internal"\n' >"$PKG/node/services/argocd/manifests/60-ingress.yaml"
  mkdir -p "$PKG/node/services/argocd/k3s" && echo 'kind: x' >"$PKG/node/services/argocd/k3s/traefik-acme.yaml"
  service argocd
  [ "$status" -eq 0 ]
  before 'ConfigMap kube-system/homelab-root-ca' 'kubectl apply -f .*/k3s/traefik-acme.yaml'
  before 'k3s/traefik-acme.yaml' 'argocd-install-v3.5.6.yaml'
  before 'services/argocd/manifests/' 'rollout restart deployment argocd-server'
}
