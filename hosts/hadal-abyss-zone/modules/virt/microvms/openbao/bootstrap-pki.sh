#!/usr/bin/env bash
set -euo pipefail

if (($# != 4)); then
  echo "usage: bootstrap-openbao-pki CA_KEY CA_CERT OPENBAO_POLICY POSTGRESQL_POLICY" >&2
  exit 2
fi

: "${BAO_ADDR:?}"
: "${BAO_CACERT:?}"
: "${BAO_TOKEN:?}"

ca_key="$1"
ca_cert="$2"
openbao_policy="$3"
postgresql_policy="$4"

for file in "$ca_key" "$ca_cert" "$openbao_policy" "$postgresql_policy"; do
  if [[ ! -s "$file" ]]; then
    echo "Missing bootstrap input: $file" >&2
    exit 1
  fi
done

if ! bao auth list -format=json | jq -e 'has("approle/")' >/dev/null; then
  bao auth enable approle
fi

if ! bao secrets list -format=json | jq -e 'has("pki/")' >/dev/null; then
  bao secrets enable pki
fi
bao secrets tune -max-lease-ttl=87600h pki

if ! bao read -format=json pki/cert/ca >/dev/null 2>&1; then
  pem_bundle="$(mktemp)"
  cleanup() {
    rm -f "$pem_bundle"
  }
  trap cleanup EXIT
  cat "$ca_key" "$ca_cert" >"$pem_bundle"
  bao write pki/config/ca pem_bundle="@$pem_bundle"
fi

bao write pki/roles/openbao-server \
  allowed_domains="openbao.home.arpa" \
  allow_bare_domains=true \
  allow_subdomains=false \
  allow_ip_sans=true \
  enforce_hostnames=true \
  server_flag=true \
  client_flag=false \
  key_type="ec" \
  key_bits=256 \
  ttl="720h" \
  max_ttl="720h" \
  generate_lease=false

bao write pki/roles/postgresql-server \
  allowed_domains="postgres.home.arpa" \
  allow_bare_domains=true \
  allow_subdomains=false \
  allow_ip_sans=true \
  enforce_hostnames=true \
  server_flag=true \
  client_flag=false \
  key_type="ec" \
  key_bits=256 \
  ttl="720h" \
  max_ttl="720h" \
  generate_lease=false

bao policy write openbao-tls "$openbao_policy"
bao policy write postgresql-tls "$postgresql_policy"

bao write auth/approle/role/openbao-tls-agent \
  token_policies="openbao-tls" \
  token_ttl="30m" \
  token_max_ttl="1h" \
  token_no_default_policy=true \
  secret_id_ttl="720h"

bao write auth/approle/role/postgresql-tls-agent \
  token_policies="postgresql-tls" \
  token_ttl="30m" \
  token_max_ttl="1h" \
  token_no_default_policy=true \
  secret_id_ttl="720h"

echo "OpenBao PKI and AppRole identities are configured."
echo "Provision each role ID and a newly generated secret ID through the bootstrap secret path."
