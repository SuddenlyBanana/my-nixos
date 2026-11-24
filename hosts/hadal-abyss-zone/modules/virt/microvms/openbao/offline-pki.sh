#!/usr/bin/env bash
set -euo pipefail
umask 077
config="$(dirname "$(readlink -f "$0")")/offline-pki.cnf"
case "${1:-}" in
  root)
    [[ $# == 2 ]]
    install -d -m 0700 "$2"
    test ! -e "$2/root.key"
    # The offline root key is passphrase encrypted. Never copy it to hadal.
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -aes-256-cbc -out "$2/root.key"
    openssl req -x509 -new -sha384 -days 3650 -key "$2/root.key" \
      -subj '/CN=Hadal offline root CA' \
      -addext 'basicConstraints=critical,CA:TRUE,pathlen:1' \
      -addext 'keyUsage=critical,keyCertSign,cRLSign' -out "$2/root.crt"
    ;;
  sign-intermediate)
    [[ $# == 5 ]]
    export OPENBAO_IP=::1
    openssl x509 -req -sha384 -days 1825 -in "$4" -CAkey "$2" -CA "$3" \
      -set_serial "0x$(openssl rand -hex 16)" -extfile "$config" -extensions intermediate -out "$5"
    ;;
  recovery)
    [[ $# == 5 ]]
    export OPENBAO_IP="$5"
    install -d -m 0700 "$4"
    test ! -e "$4/server.key"
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -config "$config" -keyout "$4/server.key" -out "$4/server.csr"
    openssl x509 -req -sha384 -days 365 -in "$4/server.csr" -CAkey "$2" -CA "$3" \
      -set_serial "0x$(openssl rand -hex 16)" -extfile "$config" -extensions recovery -out "$4/server.crt"
    install -m 0644 "$3" "$4/ca.crt"
    ;;
  *) echo 'usage: offline-pki.sh root DIR | sign-intermediate ROOT_KEY ROOT_CERT CSR OUTPUT_CERT | recovery ROOT_KEY ROOT_CERT OUTPUT_DIR OPENBAO_IP' >&2; exit 2 ;;
esac
