# OpenBao server (single node, integrated raft storage). Host network: the API listener binds the
# WireGuard address itself; the cluster port stays on loopback (no other nodes).
# shortcut: no TLS on the listener — traffic only crosses the WireGuard tunnel (encrypted); move to a
#   step-ca certificate before anything reaches OpenBao outside WireGuard.
# OpenBao has no mlock any more: swap on the machine should be off or encrypted.
ui = true

storage "raft" {
  path    = "/openbao/data"
  node_id = "homelab"
}

listener "tcp" {
  address         = "10.100.10.101:8200"
  cluster_address = "127.0.0.1:8201"
  tls_disable     = true
}

api_addr     = "http://10.100.10.101:8200"
cluster_addr = "http://127.0.0.1:8201"
