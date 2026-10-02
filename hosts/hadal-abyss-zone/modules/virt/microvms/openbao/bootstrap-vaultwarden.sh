#!/usr/bin/env bash
set -euo pipefail

if (($# != 3)); then
  echo "usage: bootstrap-openbao-vaultwarden POSTGRES_PASSWORD POSTGRES_ADDRESS POLICY" >&2
  exit 2
fi

: "${BAO_ADDR:?}"
: "${BAO_CACERT:?}"
: "${BAO_TOKEN:?}"

postgres_password_file="$1"
postgres_address="$2"
policy_file="$3"

for file in "$postgres_password_file" "$policy_file"; do
  if [[ ! -s "$file" ]]; then
    echo "Missing bootstrap input: $file" >&2
    exit 1
  fi
done

postgres_password="$(tr -d '\n' <"$postgres_password_file")"
if [[ ! "$postgres_password" =~ ^[0-9a-f]{64}$ ]]; then
  echo "The temporary PostgreSQL OpenBao password must be 64 hexadecimal characters" >&2
  exit 1
fi

if ! bao auth list -format=json | jq -e 'has("approle/")' >/dev/null; then
  bao auth enable approle
fi

bao policy write vaultwarden "$policy_file"
bao write auth/approle/role/vaultwarden \
  token_policies="vaultwarden" \
  token_ttl="30m" \
  token_max_ttl="1h" \
  token_no_default_policy=true \
  secret_id_ttl="720h"

if ! bao secrets list -format=json | jq -e 'has("database/")' >/dev/null; then
  bao secrets enable database
fi

connection_url="postgresql://{{username}}:{{password}}@[${postgres_address}]:5432/postgres?sslmode=verify-full&sslrootcert=/run/openbao-recovery-tls/ca.crt"

jq -n \
  --arg connection_url "$connection_url" \
  --arg username "openbao" \
  --arg password "$postgres_password" \
  '{
    plugin_name: "postgresql-database-plugin",
    allowed_roles: ["vaultwarden"],
    connection_url: $connection_url,
    username: $username,
    password: $password
  }' | bao write database/config/postgresql -

bao write database/roles/vaultwarden \
  db_name="postgresql" \
  default_ttl="24h" \
  max_ttl="168h" \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '\''{{password}}'\'' VALID UNTIL '\''{{expiration}}'\''; GRANT vaultwarden TO "{{name}}";' \
  revocation_statements='REVOKE vaultwarden FROM "{{name}}"; DROP ROLE IF EXISTS "{{name}}";'

# After this succeeds, the temporary management password is no longer valid or
# retrievable. OpenBao retains the replacement only in its encrypted storage.
bao write -force database/rotate-root/postgresql

echo "Vaultwarden AppRole auth and PostgreSQL dynamic role are configured."
echo "Provision its role ID and a newly generated secret ID through the bootstrap secret path."
