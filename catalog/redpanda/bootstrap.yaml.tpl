# Cluster properties read once, on the first start (installed as /etc/redpanda/.bootstrap.yaml).
# SASL on every Kafka listener (also turns on authorization); the ROOT account (created from
# RP_BOOTSTRAP_USER in redpanda.env) is the superuser and the Admin API requires it.
enable_sasl: true
superusers:
  - ${REDPANDA_ROOT_USERNAME}
admin_api_require_auth: true
