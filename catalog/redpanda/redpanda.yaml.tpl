# Redpanda node configuration (single broker). Host network: every listener binds the WireGuard
# address itself; the broker advertises that address, so clients on other machines can reconnect
# after the first contact. RPC stays on loopback (no other brokers).
redpanda:
  data_directory: /var/lib/redpanda/data
  seed_servers: []
  empty_seed_starts_cluster: true
  rpc_server:
    address: 127.0.0.1
    port: 33145
  advertised_rpc_api:
    address: 127.0.0.1
    port: 33145
  kafka_api:
    - name: wg
      address: ${WG_IP}
      port: ${PORT_9092}
      authentication_method: sasl
  advertised_kafka_api:
    - name: wg
      address: ${WG_IP}
      port: ${PORT_9092}
  admin:
    - address: ${WG_IP}
      port: ${PORT_9644}
  developer_mode: false
schema_registry:
  schema_registry_api:
    - name: wg
      address: ${WG_IP}
      port: ${PORT_8081}
      authentication_method: http_basic
