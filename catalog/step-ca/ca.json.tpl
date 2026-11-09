{
  "root": "/home/step/certs/root_ca.crt",
  "crt": "/home/step/certs/intermediate_ca.crt",
  "key": "/home/step/secrets/intermediate_ca.key",
  "address": ":9000",
  "dnsNames": ["ca.${DOMAIN}", "${WG_IP}"],
  "logger": {"format": "text"},
  "db": {"type": "badgerv2", "dataSource": "/home/step/db"},
  "authority": {
    "provisioners": [
      {
        "type": "ACME",
        "name": "acme",
        "claims": {"defaultTLSCertDuration": "720h", "maxTLSCertDuration": "2160h"}
      }
    ]
  },
  "tls": {"minVersion": 1.2, "maxVersion": 1.3, "renegotiation": false}
}
