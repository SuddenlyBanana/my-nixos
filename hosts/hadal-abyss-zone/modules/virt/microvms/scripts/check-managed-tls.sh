#!/usr/bin/env bash
set -euo pipefail

: "${TLS_CERTIFICATE:?}"
: "${TLS_SERVER_NAME:?}"
: "${TLS_WARNING_SECONDS:?}"

openssl x509 -in "$TLS_CERTIFICATE" -noout -checkhost "$TLS_SERVER_NAME"
if ! openssl x509 -in "$TLS_CERTIFICATE" -noout -checkend "$TLS_WARNING_SECONDS"; then
  echo "Certificate for ${TLS_SERVER_NAME} expires within ${TLS_WARNING_SECONDS} seconds" >&2
  exit 1
fi
