#!/usr/bin/env bash
# Step 10: Docker Engine + compose plugin from Docker's apt repository, only when the machine runs
# a service under Docker (COMPOSE_SERVICES in node.env). The repository key is checked against its
# published fingerprint before apt trusts it.
set -Eeuo pipefail
# shellcheck source=common/lib.sh
source "$(dirname "$0")/lib.sh"
parse_common_args "$@"
require_root
load_node_env

# Docker Release (CE deb) key, https://docs.docker.com/engine/install/debian/
DOCKER_GPG_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.list
# Fixed bridge pool, so it never overlaps k3s (10.42/16, 10.43/16) or WireGuard (10.100.10.0/24).
DOCKER_BIP=172.17.0.1/16

docker_install() {
  local codename arch key_tmp
  codename=$(os_release_value VERSION_CODENAME)
  [[ $codename =~ ^[a-z]+$ ]] || die "cannot read VERSION_CODENAME from $HOMELAB_OS_RELEASE"
  arch=$(dpkg --print-architecture)
  [[ $arch =~ ^[a-z0-9]+$ ]] || die "unexpected dpkg architecture: $arch"
  write_file /etc/docker/daemon.json <<EOF
{
  "bip": "$DOCKER_BIP",
  "log-driver": "local"
}
EOF
  key_tmp=$DOCKER_KEYRING.download
  run install -d -m 755 /etc/apt/keyrings
  fetch "https://download.docker.com/linux/$OS/gpg" "$key_tmp"
  verify_gpg_fingerprint "$key_tmp" "$DOCKER_GPG_FINGERPRINT"
  run install -m 644 "$key_tmp" "$DOCKER_KEYRING"
  run rm -f "$key_tmp"
  echo "deb [arch=$arch signed-by=$DOCKER_KEYRING] https://download.docker.com/linux/$OS $codename stable" |
    write_file "$DOCKER_SOURCES"
  run env DEBIAN_FRONTEND=noninteractive apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  if in_container; then container_skip "starting dockerd (needs a privileged container)"; else
    run systemctl enable --now docker
  fi
}

if [[ -z ${COMPOSE_SERVICES:-} ]]; then
  log_info "step 10: no service of $NODE_NAME runs under Docker, skipping"
  exit 0
fi
step 10 docker_install
