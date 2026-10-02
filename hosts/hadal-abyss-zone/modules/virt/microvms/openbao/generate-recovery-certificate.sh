#!/usr/bin/env bash
set -euo pipefail

: "${OPENBAO_ADDRESS:?}"
: "${OPENBAO_DNS_NAME:?}"
: "${OPENBAO_RECOVERY_DIR:?}"
: "${OPENBAO_RECOVERY_IMAGE:?}"
: "${OPENBAO_CA_IMAGE:?}"

ca_key="${OPENBAO_RECOVERY_DIR}/ca.key"
ca_cert="${OPENBAO_RECOVERY_DIR}/ca.crt"
server_key="${OPENBAO_RECOVERY_DIR}/server.key"
server_csr="${OPENBAO_RECOVERY_DIR}/server.csr"
server_cert="${OPENBAO_RECOVERY_DIR}/server.crt"

install -d -m 0700 "$OPENBAO_RECOVERY_DIR"

if [[ -s "$OPENBAO_RECOVERY_IMAGE" && -s "$OPENBAO_CA_IMAGE" ]]; then
  exit 0
fi

if [[ -e "$OPENBAO_RECOVERY_IMAGE" || -e "$OPENBAO_CA_IMAGE" ]]; then
  echo "Only one OpenBao recovery TLS volume exists; refusing to create a mismatched pair" >&2
  exit 1
fi

if [[ ! -s "$ca_key" || ! -s "$ca_cert" ]]; then
  # Keep the trust anchor valid beyond the long-lived recovery leaf so their
  # expirations do not coincide during a recovery operation.
  openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 4015 \
    -subj "/CN=hadal OpenBao service CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "${ca_key}.new" -out "${ca_cert}.new"
  mv "${ca_key}.new" "$ca_key"
  mv "${ca_cert}.new" "$ca_cert"
fi

if [[ ! -s "$server_key" || ! -s "$server_cert" ]]; then
  openssl req -new -newkey rsa:3072 -sha256 -nodes \
    -subj "/CN=${OPENBAO_DNS_NAME}" \
    -addext "subjectAltName=DNS:${OPENBAO_DNS_NAME},IP:${OPENBAO_ADDRESS}" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    -keyout "${server_key}.new" -out "${server_csr}.new"
  openssl x509 -req -sha256 -days 3650 \
    -in "${server_csr}.new" -CA "$ca_cert" -CAkey "$ca_key" \
    -CAcreateserial -copy_extensions copyall -out "${server_cert}.new"
  mv "${server_key}.new" "$server_key"
  mv "${server_csr}.new" "$server_csr"
  mv "${server_cert}.new" "$server_cert"
fi

chown root:root "$ca_key" "$ca_cert" "$server_key" "$server_csr" "$server_cert"
chmod 0600 "$ca_key" "$server_key"
chmod 0644 "$ca_cert" "$server_csr" "$server_cert"

recovery_stage="$(mktemp -d)"
ca_stage="$(mktemp -d)"
cleanup() {
  rm -rf "$recovery_stage" "$ca_stage"
}
trap cleanup EXIT

install -m 0600 "$server_key" "${recovery_stage}/server.key"
install -m 0644 "$server_cert" "${recovery_stage}/server.crt"
install -m 0644 "$ca_cert" "${recovery_stage}/ca.crt"
install -m 0644 "$ca_cert" "${ca_stage}/ca.crt"

touch "${OPENBAO_RECOVERY_IMAGE}.new" "${OPENBAO_CA_IMAGE}.new"
chattr +C "${OPENBAO_RECOVERY_IMAGE}.new" "${OPENBAO_CA_IMAGE}.new" || true
truncate -s 16M "${OPENBAO_RECOVERY_IMAGE}.new" "${OPENBAO_CA_IMAGE}.new"
mkfs.ext4 -q -F -L openbao-recovery-tls -d "$recovery_stage" "${OPENBAO_RECOVERY_IMAGE}.new"
mkfs.ext4 -q -F -L openbao-ca -d "$ca_stage" "${OPENBAO_CA_IMAGE}.new"
chown root:kvm "${OPENBAO_RECOVERY_IMAGE}.new" "${OPENBAO_CA_IMAGE}.new"
chmod 0640 "${OPENBAO_RECOVERY_IMAGE}.new" "${OPENBAO_CA_IMAGE}.new"
mv "${OPENBAO_RECOVERY_IMAGE}.new" "$OPENBAO_RECOVERY_IMAGE"
mv "${OPENBAO_CA_IMAGE}.new" "$OPENBAO_CA_IMAGE"

# Only the CA is needed for the one-time PKI import. Do not leave a second
# copy of the recovery listener's private key on the host filesystem.
rm -f "$server_key" "$server_csr" "$server_cert" \
  "${OPENBAO_RECOVERY_DIR}/ca.srl" "${ca_cert}.srl"
