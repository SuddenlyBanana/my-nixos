#!/usr/bin/env bash
set -euo pipefail
bootstrap=/run/hadal-bootstrap
managed=/var/lib/openbao/tls
recovery=/var/lib/openbao/recovery-tls

for file in ca.crt server.crt server.key; do
  test -s "$bootstrap/$file"
done
openssl verify -CAfile "$bootstrap/ca.crt" -untrusted "$bootstrap/server.crt" \
  -verify_hostname openbao.home.arpa "$bootstrap/server.crt"
openssl x509 -in "$bootstrap/server.crt" -noout -checkend 86400
cmp -s <(openssl pkey -in "$bootstrap/server.key" -pubout) \
  <(openssl x509 -in "$bootstrap/server.crt" -pubkey -noout)
install -d -m 0700 -o openbao -g openbao "$recovery" "$managed/versions/bootstrap" /var/lib/openbao/tls-staging
install -m 0600 -o openbao -g openbao "$bootstrap/server.key" "$recovery/server.key"
install -m 0644 -o openbao -g openbao "$bootstrap/server.crt" "$recovery/server.crt"
install -m 0644 -o openbao -g openbao "$bootstrap/ca.crt" "$recovery/ca.crt"
if [[ ! -L "$managed/current" || "$(readlink "$managed/current")" == versions/bootstrap ]]; then
  install -m 0600 -o openbao -g openbao "$bootstrap/server.key" "$managed/versions/bootstrap/server.key"
  install -m 0644 -o openbao -g openbao "$bootstrap/server.crt" "$managed/versions/bootstrap/server.crt"
  ln -sfn versions/bootstrap "$managed/current"
fi
