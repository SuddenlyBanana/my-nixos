#!/usr/bin/env bash
set -euo pipefail

: "${CREDENTIAL_DIR:?}"
: "${CREDENTIAL_IMAGE:?}"
: "${POSTGRES_ADDRESS:?}"
: "${POSTGRES_CA:?}"

password_file="${CREDENTIAL_DIR}/postgresql.password"
environment_file="${CREDENTIAL_DIR}/vaultwarden.env"

install -d -m 0700 "$CREDENTIAL_DIR"

if [[ -s "$CREDENTIAL_IMAGE" ]]; then
  exit 0
fi

if [[ ! -s "$password_file" ]]; then
  openssl rand -hex 32 >"${password_file}.new"
  chmod 0400 "${password_file}.new"
  mv "${password_file}.new" "$password_file"
fi

password="$(tr -d '\n' <"$password_file")"
if [[ ! "$password" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Unexpected Vaultwarden PostgreSQL password format" >&2
  exit 1
fi

database_url="postgresql://vaultwarden:${password}@[${POSTGRES_ADDRESS}]:5432/vaultwarden?sslmode=verify-full&sslrootcert=${POSTGRES_CA}"
printf 'DATABASE_URL=%s\n' "$database_url" >"${environment_file}.new"
chmod 0400 "${environment_file}.new"
mv "${environment_file}.new" "$environment_file"

image_new="${CREDENTIAL_IMAGE}.new"
touch "$image_new"
chattr +C "$image_new" || true
truncate -s 8M "$image_new"
mkfs.ext4 -q -F -L vaultwarden-creds -d "$CREDENTIAL_DIR" "$image_new"
chown root:kvm "$image_new"
chmod 0640 "$image_new"
mv "$image_new" "$CREDENTIAL_IMAGE"
