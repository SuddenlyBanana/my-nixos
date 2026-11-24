#!/usr/bin/env bash
set -euo pipefail
umask 077
: "${CREDENTIALS_DIRECTORY:?}"
export BAO_TOKEN
BAO_TOKEN="$(bao write -format=json auth/approle/login \
  role_id=@"$CREDENTIALS_DIRECTORY/role-id" \
  secret_id=@"$CREDENTIALS_DIRECTORY/secret-id" | jq -er '.auth.client_token')"
trap 'bao token revoke -self >/dev/null || true; unset BAO_TOKEN' EXIT
bao operator raft snapshot save /run/restic-backups-openbao/raft.snap
