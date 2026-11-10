#!/usr/bin/env bash
set -euo pipefail
umask 077
: "${BAO_ADDR:?}"
: "${BAO_CACERT:?}"
: "${BAO_TOKEN:?}"

case "${1:-}" in
  generate-csr)
    [[ $# == 2 ]]
    if ! bao secrets list -format=json | jq -e 'has("pki/")' >/dev/null; then
      bao secrets enable pki
    fi
    test ! -e "$2"
    bao write -format=json pki/intermediate/generate/internal \
      common_name='Hadal service intermediate CA' key_type=ec key_bits=256 \
      | jq -er '.data.csr' >"$2"
    echo 'Sign this CSR on the offline CA machine. No CA private key leaves that machine.'
    exit 0
    ;;
  rotate-approle)
    [[ $# == 3 ]]
    case "$2" in openbao-tls-agent|postgresql-tls-agent|openbao-backup) ;; *) exit 2 ;; esac
    install -d -m 0700 "$3"
    bao read -field=role_id "auth/approle/role/$2/role-id" >"$3/role-id"
    bao write -force -field=secret_id "auth/approle/role/$2/secret-id" >"$3/secret-id"
    echo 'Encrypt these files in private-nixos, update the secrets input, and rebuild hadal.'
    exit 0
    ;;
  configure-backups)
    [[ $# == 2 ]]
    bao policy write openbao-backup "$2"
    bao write auth/approle/role/openbao-backup \
      token_policies=openbao-backup token_ttl=5m token_max_ttl=30m \
      token_no_default_policy=true secret_id_ttl=720h
    exit 0
    ;;
  install)
    [[ $# == 5 ]]
    signed_intermediate="$2"
    root_cert="$3"
    openbao_policy="$4"
    postgresql_policy="$5"
    : "${OPENBAO_ADDRESS:?Set the allowed OpenBao IPv6 SAN}"
    : "${POSTGRESQL_ADDRESS:?Set the allowed PostgreSQL IPv6 SAN}"
    ;;
  *) echo 'usage: bootstrap-openbao-pki generate-csr OUTPUT | install INTERMEDIATE_CERT ROOT_CERT OPENBAO_POLICY POSTGRESQL_POLICY | rotate-approle ROLE OUTPUT_DIR' >&2; exit 2 ;;
esac

openssl verify -CAfile "$root_cert" "$signed_intermediate"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
cat "$signed_intermediate" "$root_cert" >"$work_dir/chain.pem"
bao write pki/intermediate/set-signed certificate=@"$work_dir/chain.pem"
bao secrets tune -max-lease-ttl=43800h pki
if ! bao auth list -format=json | jq -e 'has("approle/")' >/dev/null; then
  bao auth enable approle
fi
for specification in openbao:openbao.home.arpa postgresql:postgres.home.arpa; do
  service="${specification%%:*}"
  dns_name="${specification#*:}"
  if [[ "$service" == openbao ]]; then server_address="$OPENBAO_ADDRESS"; else server_address="$POSTGRESQL_ADDRESS"; fi
  bao write "pki/roles/$service-server" \
    allowed_domains="$dns_name" allow_bare_domains=true allow_subdomains=false \
    allow_localhost=false allow_wildcard_certificates=false \
    allow_ip_sans=true allowed_ip_sans_cidr="$server_address/128" \
    enforce_hostnames=true server_flag=true client_flag=false \
    key_type=ec key_bits=256 ttl=720h max_ttl=720h generate_lease=false
  bao write "auth/approle/role/$service-tls-agent" \
    token_policies="$service-tls" token_ttl=30m token_max_ttl=1h \
    token_no_default_policy=true secret_id_ttl=720h
done
bao policy write openbao-tls "$openbao_policy"
bao policy write postgresql-tls "$postgresql_policy"
echo 'Intermediate and TLS roles installed. Rotate/deliver AppRole credentials before their 30-day expiry.'
