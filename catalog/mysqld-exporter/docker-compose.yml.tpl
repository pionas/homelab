# mysqld_exporter: logs in with the read-only VIEWER account; host network, listening on the
# WireGuard address only. The password comes from mysqld-exporter.env (mode 600), not the command line.
services:
  mysqld-exporter:
    image: quay.io/prometheus/mysqld-exporter:v0.21.0
    restart: unless-stopped
    network_mode: host
    env_file: ./mysqld-exporter.env
    command:
      - "--web.listen-address=${WG_IP}:9104"
      - "--mysqld.address=${WG_IP}:3306"
      - "--mysqld.username=${MARIADB_VIEWER_USERNAME}"
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
