#!/usr/bin/env bash
set -euo pipefail

recovery_mount="/run/openbao-recovery-tls"
managed_root="/var/lib/openbao/tls"
bootstrap_dir="${managed_root}/versions/bootstrap"

for file in ca.crt server.crt server.key; do
  if [[ ! -s "${recovery_mount}/${file}" ]]; then
    echo "Missing OpenBao recovery TLS file: ${recovery_mount}/${file}" >&2
    exit 1
  fi
done

chown root:openbao "${recovery_mount}/ca.crt" "${recovery_mount}/server.crt"
chmod 0644 "${recovery_mount}/ca.crt" "${recovery_mount}/server.crt"
chown openbao:openbao "${recovery_mount}/server.key"
chmod 0400 "${recovery_mount}/server.key"
mount -o remount,ro "$recovery_mount"

install -d -m 0700 -o openbao -g openbao "$managed_root/versions"
install -d -m 0700 -o openbao -g openbao /var/lib/openbao/tls-staging

if [[ ! -L "$managed_root/current" ]]; then
  install -d -m 0700 -o openbao -g openbao "$bootstrap_dir"
  install -m 0600 -o openbao -g openbao \
    "$recovery_mount/server.key" "$bootstrap_dir/server.key"
  install -m 0644 -o openbao -g openbao \
    "$recovery_mount/server.crt" "$bootstrap_dir/server.crt"
  ln -s "versions/bootstrap" "$managed_root/current"
fi
