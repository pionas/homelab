#!/usr/bin/env bash
# Step 01: base system, admin user with SSH key, sshd hardening (Port $SSH_PORT).
# Order matters: the admin's key is verified and installed, and sudo works, before passwords and
# root login are switched off; `sshd -t` runs before `reload` (never restart: it would drop sessions).
set -Eeuo pipefail
# shellcheck source=common/lib.sh
source "$(dirname "$0")/lib.sh"
parse_common_args "$@"
require_root
load_node_env

ADMIN_USER=${HOMELAB_ADMIN_USER:-admin}
TIMEZONE=${HOMELAB_TIMEZONE:-Etc/UTC}
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-homelab.conf
SUDOERS_FILE=/etc/sudoers.d/90-homelab-admin

# Both end up in commands and files run or read as root: plain values only.
[[ $ADMIN_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $ADMIN_USER != root ]] ||
  die "HOMELAB_ADMIN_USER must be a lowercase user name other than root, got: $ADMIN_USER"
[[ $TIMEZONE =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || die "HOMELAB_TIMEZONE must look like Region/City, got: $TIMEZONE"

# The keys of the account running the install: the ones that just worked to log in.
admin_keys_source() {
  if [[ -n ${HOMELAB_ADMIN_KEYS:-} ]]; then
    echo "$HOMELAB_ADMIN_KEYS"
  elif [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    echo "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys"
  else
    echo /root/.ssh/authorized_keys
  fi
}

apt_noninteractive() { run env DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

base_packages() {
  apt_noninteractive update
  apt_noninteractive -y upgrade
  apt_noninteractive install -y chrony fail2ban unattended-upgrades wireguard wireguard-tools ufw \
    ca-certificates curl sudo openssl
}

base_system() {
  if in_container; then container_skip "hostname $NODE_NAME (set by the container runtime)"; else
    run hostnamectl set-hostname "$NODE_NAME"
  fi
  run timedatectl set-timezone "$TIMEZONE"
  run systemctl enable --now chrony
  write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  write_file /etc/apt/apt.conf.d/52homelab-unattended <<'EOF'
// Reboots are planned by hand: an automatic one could stop a database or a cluster at any time.
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  write_file /etc/fail2ban/jail.d/homelab.conf <<EOF
[DEFAULT]
# Never ban the WireGuard network (admin devices and the other machines).
ignoreip = 127.0.0.1/8 ::1 $HOMELAB_WG_NET

[sshd]
enabled = true
port = $SSH_PORT
backend = systemd
EOF
  run systemctl enable fail2ban
  run systemctl restart fail2ban
  echo 'net.ipv4.ip_forward = 1' | write_file /etc/sysctl.d/90-homelab.conf
  # Only this file: `sysctl --system` would also re-apply every other sysctl.d file.
  if in_container; then container_skip "sysctl (read-only /proc/sys)"; else
    run sysctl -p /etc/sysctl.d/90-homelab.conf
  fi
}

admin_user() {
  local src home=/home/$ADMIN_USER
  src=$(admin_keys_source)
  [[ $src == /* && $src != *..* && $src != *$'\n'* ]] || die "admin keys path must be absolute without .., got: $src"
  # Checked before anything changes: once passwords are off these keys are the only way in.
  if ! [[ -s $src ]] || ! ssh-keygen -l -f "$src" >/dev/null 2>&1; then
    die "no valid SSH public key in $src; the admin user would be locked out (set HOMELAB_ADMIN_KEYS)"
  fi
  if id -u "$ADMIN_USER" >/dev/null 2>&1; then
    log_info "user $ADMIN_USER exists"
  else
    run useradd --create-home --shell /bin/bash "$ADMIN_USER"
  fi
  run install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
  run install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" "$src" "$home/.ssh/authorized_keys"
  if ! ((DRY_RUN)); then
    ssh-keygen -l -f "$home/.ssh/authorized_keys" >/dev/null || die "authorized_keys of $ADMIN_USER is not readable as SSH keys"
  fi
  # The admin has no password, so sudo must not ask for one.
  echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" | write_file "$SUDOERS_FILE" 440
  run visudo -cf "$SUDOERS_FILE"
}

ssh_hardening() {
  write_file "$SSHD_DROPIN" <<EOF
# Managed by homelab (common/01-base.sh). sshd_config includes this directory first: these values win.
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
  run sshd -t
  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    # Socket activation (Ubuntu): the listening port comes from a unit generated from sshd_config.
    run systemctl daemon-reload
    run systemctl restart ssh.socket
  else
    run systemctl reload ssh
  fi
  local port
  port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
  if ((DRY_RUN)); then
    log_info "sshd listens on port ${port:-unknown} now, on $SSH_PORT after this step"
  elif [[ $port != "$SSH_PORT" ]]; then
    die "sshd listens on $port, expected $SSH_PORT: check other files in /etc/ssh/sshd_config.d"
  fi
}

base_install() {
  base_packages
  base_system
  admin_user
  ssh_hardening
}

step 01 base_install
