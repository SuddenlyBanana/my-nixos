#!/usr/bin/env bash
set -euo pipefail

password_file=/var/lib/nut-secrets/upsmon-password
if [[ -s "$password_file" ]]; then
  exit 0
fi

temporary_file=$(mktemp /var/lib/nut-secrets/.upsmon-password.XXXXXX)
trap 'rm -f "$temporary_file"' EXIT
openssl rand -hex 32 > "$temporary_file"
chmod 0400 "$temporary_file"
mv "$temporary_file" "$password_file"
