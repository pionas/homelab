# Redpanda (BSL/RCL, decision "broker"): Kafka API with SASL/SCRAM, Schema Registry with Basic auth,
# Admin API (and metrics on /public_metrics) with auth — all only on the WireGuard address (host
# network, see redpanda.yaml). The bootstrap user's password comes from redpanda.env (mode 600).
services:
  redpanda:
    image: redpandadata/redpanda:v26.2.6
    restart: unless-stopped
    network_mode: host
    env_file: ./redpanda.env
    command: ["redpanda", "start", "--overprovisioned", "--smp", "1", "--memory", "1G", "--default-log-level=info"]
    volumes:
      - "./config:/etc/redpanda"
      - "/var/lib/homelab/data/redpanda:/var/lib/redpanda/data"
    security_opt: ["no-new-privileges:true"]
