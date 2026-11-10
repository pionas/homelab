# Policy of the token External Secrets uses (created by install.sh): read the homelab KV store only.
path "homelab/data/*" {
  capabilities = ["read"]
}

path "homelab/metadata/*" {
  capabilities = ["read", "list"]
}
