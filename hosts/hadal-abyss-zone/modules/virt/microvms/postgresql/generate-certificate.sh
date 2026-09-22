#!/usr/bin/env bash
set -euo pipefail

: "${POSTGRES_ADDRESS:?}"
: "${POSTGRES_DNS_NAME:?}"
: "${POSTGRES_TLS_DIR:?}"
: "${POSTGRES_TLS_IMAGE:?}"
: "${POSTGRES_CA_IMAGE:?}"
: "${POSTGRES_UID:?}"
: "${POSTGRES_GID:?}"

ca_key="${POSTGRES_TLS_DIR}/ca.key"
ca_cert="${POSTGRES_TLS_DIR}/ca.crt"
server_key="${POSTGRES_TLS_DIR}/server.key"
server_csr="${POSTGRES_TLS_DIR}/server.csr"
server_cert="${POSTGRES_TLS_DIR}/server.crt"

install -d -m 0700 "$POSTGRES_TLS_DIR"

if [[ -s "$POSTGRES_TLS_IMAGE" && -s "$POSTGRES_CA_IMAGE" ]]; then
  exit 0
fi

if [[ -e "$POSTGRES_TLS_IMAGE" || -e "$POSTGRES_CA_IMAGE" ]]; then
  echo "Only one PostgreSQL TLS volume exists; refusing to create a mismatched pair" >&2
  exit 1
fi

if [[ ! -s "$ca_key" || ! -s "$ca_cert" ]]; then
  openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 \
    -subj "/CN=hadal PostgreSQL service CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "${ca_key}.new" -out "${ca_cert}.new"
  mv "${ca_key}.new" "$ca_key"
  mv "${ca_cert}.new" "$ca_cert"
fi

if [[ ! -s "$server_key" || ! -s "$server_cert" ]]; then
  openssl req -new -newkey rsa:3072 -sha256 -nodes \
    -subj "/CN=${POSTGRES_DNS_NAME}" \
    -addext "subjectAltName=DNS:${POSTGRES_DNS_NAME},IP:${POSTGRES_ADDRESS}" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    -keyout "${server_key}.new" -out "${server_csr}.new"
  openssl x509 -req -sha256 -days 825 \
    -in "${server_csr}.new" -CA "$ca_cert" -CAkey "$ca_key" \
    -CAcreateserial -copy_extensions copyall -out "${server_cert}.new"
  mv "${server_key}.new" "$server_key"
  mv "${server_csr}.new" "$server_csr"
  mv "${server_cert}.new" "$server_cert"
fi

chown root:root "$ca_key" "$ca_cert"
chmod 0600 "$ca_key"
chmod 0644 "$ca_cert"
chown "${POSTGRES_UID}:${POSTGRES_GID}" "$server_key" "$server_csr" "$server_cert"
chmod 0600 "$server_key"
chmod 0644 "$server_csr" "$server_cert"

tls_stage="$(mktemp -d)"
ca_stage="$(mktemp -d)"
cleanup() {
  rm -rf "$tls_stage" "$ca_stage"
}
trap cleanup EXIT

install -m 0600 -o "$POSTGRES_UID" -g "$POSTGRES_GID" "$server_key" "${tls_stage}/server.key"
install -m 0644 -o "$POSTGRES_UID" -g "$POSTGRES_GID" "$server_cert" "${tls_stage}/server.crt"
install -m 0644 "$ca_cert" "${ca_stage}/ca.crt"

touch "${POSTGRES_TLS_IMAGE}.new" "${POSTGRES_CA_IMAGE}.new"
chattr +C "${POSTGRES_TLS_IMAGE}.new" "${POSTGRES_CA_IMAGE}.new" || true
truncate -s 8M "${POSTGRES_TLS_IMAGE}.new" "${POSTGRES_CA_IMAGE}.new"
mkfs.ext4 -q -F -L postgresql-tls -d "$tls_stage" "${POSTGRES_TLS_IMAGE}.new"
mkfs.ext4 -q -F -L postgresql-ca -d "$ca_stage" "${POSTGRES_CA_IMAGE}.new"
chown root:kvm "${POSTGRES_TLS_IMAGE}.new" "${POSTGRES_CA_IMAGE}.new"
chmod 0640 "${POSTGRES_TLS_IMAGE}.new" "${POSTGRES_CA_IMAGE}.new"
mv "${POSTGRES_TLS_IMAGE}.new" "$POSTGRES_TLS_IMAGE"
mv "${POSTGRES_CA_IMAGE}.new" "$POSTGRES_CA_IMAGE"
