# redis_exporter (supports Valkey): logs in with the read-only VIEWER ACL user; host network,
# listening on the WireGuard address only. The password comes from redis-exporter.env (mode 600).
services:
  redis-exporter:
    image: oliver006/redis_exporter:v1.96.0
    restart: unless-stopped
    network_mode: host
    env_file: ./redis-exporter.env
    environment:
      REDIS_ADDR: "redis://${WG_IP}:${VALKEY_PORT_6379}"
      REDIS_USER: "${VALKEY_VIEWER_USERNAME}"
      REDIS_EXPORTER_WEB_LISTEN_ADDRESS: "${WG_IP}:${PORT_9121}"
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
