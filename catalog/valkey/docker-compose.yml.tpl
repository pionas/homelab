# Valkey (BSD-3, Redis protocol) instead of Redis 8 (decision "cache" in the install plan).
# Published only on the WireGuard address; data stays on the host when the container is removed.
services:
  valkey:
    image: valkey/valkey:9.0.6
    restart: unless-stopped
    command: ["valkey-server", "/etc/valkey/valkey.conf"]
    ports:
      - "${WG_IP}:6379:6379"
    volumes:
      - "./valkey.conf:/etc/valkey/valkey.conf:ro"
      - "./users.acl:/etc/valkey/users.acl:ro"
      - "/var/lib/homelab/data/valkey:/data"
    security_opt: ["no-new-privileges:true"]
