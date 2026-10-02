#!/usr/bin/env bash
set -euo pipefail

: "${TLS_BUNDLE:?}"
: "${TLS_OUTPUT_DIR:?}"
: "${TLS_OWNER:?}"
: "${TLS_GROUP:?}"
: "${TLS_SERVER_NAME:?}"
: "${TLS_SERVICE_UNIT:?}"
: "${TLS_START_UNIT:?}"

if [[ ! -s "$TLS_BUNDLE" ]]; then
  echo "Managed TLS bundle is missing: $TLS_BUNDLE" >&2
  exit 1
fi

install -d -m 0700 -o "$TLS_OWNER" -g "$TLS_GROUP" "$TLS_OUTPUT_DIR/versions"
exec 9>"$TLS_OUTPUT_DIR/.activation.lock"
flock 9

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

key_file="$work_dir/server.key"
cert_file="$work_dir/server.crt"

sed -n '/^-----BEGIN .*PRIVATE KEY-----$/,/^-----END .*PRIVATE KEY-----$/p' \
  "$TLS_BUNDLE" >"$key_file"
sed -n '/^-----BEGIN CERTIFICATE-----$/,/^-----END CERTIFICATE-----$/p' \
  "$TLS_BUNDLE" >"$cert_file"

openssl pkey -in "$key_file" -check -noout
openssl x509 -in "$cert_file" -noout -checkhost "$TLS_SERVER_NAME"
openssl x509 -in "$cert_file" -noout -checkend 86400
openssl verify -CAfile "$cert_file" "$cert_file"

openssl pkey -in "$key_file" -pubout -out "$work_dir/key.pub"
openssl x509 -in "$cert_file" -pubkey -noout >"$work_dir/cert.pub"
cmp --silent "$work_dir/key.pub" "$work_dir/cert.pub"

serial="$(openssl x509 -in "$cert_file" -noout -serial | cut -d= -f2)"
if [[ ! "$serial" =~ ^[0-9A-Fa-f]+$ ]]; then
  echo "Certificate serial is not hexadecimal" >&2
  exit 1
fi

version_dir="$TLS_OUTPUT_DIR/versions/$serial"
install -d -m 0700 -o "$TLS_OWNER" -g "$TLS_GROUP" "$version_dir"
install -m 0600 -o "$TLS_OWNER" -g "$TLS_GROUP" "$key_file" "$version_dir/server.key"
install -m 0644 -o "$TLS_OWNER" -g "$TLS_GROUP" "$cert_file" "$version_dir/server.crt"

old_target=""
if [[ -L "$TLS_OUTPUT_DIR/current" ]]; then
  old_target="$(readlink "$TLS_OUTPUT_DIR/current")"
fi

rm -f "$TLS_OUTPUT_DIR/current.new" "$TLS_OUTPUT_DIR/current.rollback"
ln -s "versions/$serial" "$TLS_OUTPUT_DIR/current.new"
mv -Tf "$TLS_OUTPUT_DIR/current.new" "$TLS_OUTPUT_DIR/current"

if systemctl is-active --quiet "$TLS_SERVICE_UNIT"; then
  if ! systemctl reload "$TLS_SERVICE_UNIT"; then
    if [[ -n "$old_target" ]]; then
      ln -s "$old_target" "$TLS_OUTPUT_DIR/current.rollback"
      mv -Tf "$TLS_OUTPUT_DIR/current.rollback" "$TLS_OUTPUT_DIR/current"
      systemctl reload "$TLS_SERVICE_UNIT" || true
    else
      rm -f "$TLS_OUTPUT_DIR/current"
    fi
    exit 1
  fi
else
  systemctl start "$TLS_START_UNIT"
fi
