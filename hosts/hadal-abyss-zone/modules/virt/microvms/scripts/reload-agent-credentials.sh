#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 ]]
unit="openbao-agent-$1.service"
source_dir="$2"
ca_file="$3"
for file in "$source_dir/role-id" "$source_dir/secret-id" "$ca_file"; do
  # The initial OpenBao guest deliberately starts without an AppRole.
  test -s "$file" || exit 0
done
if systemctl is-active --quiet "$unit" \
  && cmp -s "$source_dir/role-id" "/run/credentials/$unit/role-id" \
  && cmp -s "$source_dir/secret-id" "/run/credentials/$unit/secret-id" \
  && cmp -s "$ca_file" "/run/credentials/$unit/ca.crt"; then
  exit 0
fi
systemctl restart "$unit"
