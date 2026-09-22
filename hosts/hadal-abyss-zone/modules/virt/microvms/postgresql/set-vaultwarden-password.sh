#!/usr/bin/env bash
set -euo pipefail

: "${PASSWORD_FILE:?}"

password="$(tr -d '\n' <"$PASSWORD_FILE")"
if [[ ! "$password" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Unexpected Vaultwarden PostgreSQL password format" >&2
  exit 1
fi

runuser -u postgres -- psql \
  --dbname=postgres --set=ON_ERROR_STOP=1 --set=password="$password" <<'SQL'
ALTER ROLE vaultwarden WITH LOGIN PASSWORD :'password';
SQL
