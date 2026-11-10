#!/usr/bin/env bash
set -euo pipefail
script_dir="$(dirname "$(readlink -f "$0")")"
test_dir="$(mktemp -d /tmp/hadal-pki-test.XXXXXX)"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf "$test_dir"
}
trap cleanup EXIT
umask 077
# A throwaway test CA; production uses the encrypted offline-root command.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes -days 2 \
  -subj /CN=test-offline-root -addext 'basicConstraints=critical,CA:TRUE,pathlen:1' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' -keyout "$test_dir/root.key" -out "$test_dir/root.crt"
test_port="${HADAL_PKI_TEST_PORT:-19200}"
export BAO_ADDR="http://127.0.0.1:$test_port" BAO_TOKEN=hadal-pki-test-only BAO_CACERT="$test_dir/root.crt"
export OPENBAO_ADDRESS=::1 POSTGRESQL_ADDRESS=::2
jq -n --arg file "$test_dir/audit.json" \
  '{audit:[{file:{file:{description:"Hadal service audit log",options:{file_path:$file,log_raw:"false"}}}}]}' >"$test_dir/server.json"
bao server -config="$test_dir/server.json" -dev -dev-no-store-token -dev-root-token-id="$BAO_TOKEN" -dev-listen-address="127.0.0.1:$test_port" >"$test_dir/openbao.log" 2>&1 &
server_pid=$!
ready=false
for _ in {1..100}; do
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$test_dir/openbao.log"; exit 1; fi
  # Do not mistake an unrelated listener on the test port for our own server.
  if rg -q 'OpenBao server started' "$test_dir/openbao.log" && bao status >/dev/null 2>&1; then ready=true; break; fi
  sleep 0.1
done
$ready || { cat "$test_dir/openbao.log"; exit 1; }
bash "$script_dir/bootstrap-pki.sh" generate-csr "$test_dir/intermediate.csr"
bash "$script_dir/offline-pki.sh" sign-intermediate "$test_dir/root.key" "$test_dir/root.crt" \
  "$test_dir/intermediate.csr" "$test_dir/intermediate.crt"
bash "$script_dir/bootstrap-pki.sh" install "$test_dir/intermediate.crt" "$test_dir/root.crt" \
  "$script_dir/openbao-tls-policy.hcl" "$script_dir/postgresql-tls-policy.hcl"
bao write -format=json pki/issue/openbao-server common_name=openbao.home.arpa ip_sans=::1 ttl=1h \
  | jq -er '.data.certificate' >"$test_dir/leaf.crt"
openssl verify -CAfile "$test_dir/root.crt" -untrusted "$test_dir/intermediate.crt" \
  -verify_hostname openbao.home.arpa "$test_dir/leaf.crt"
if bao write pki/issue/openbao-server common_name=openbao.home.arpa ip_sans=::2 ttl=1h >/dev/null 2>&1; then
  echo 'Wrong-service IP SAN was accepted' >&2; exit 1
fi
bao read -field=certificate pki/cert/ca_chain >"$test_dir/ca-chain.crt"
[[ "$(openssl crl2pkcs7 -nocrl -certfile "$test_dir/ca-chain.crt" | openssl pkcs7 -print_certs | rg -c '^subject=')" == 2 ]]
[[ "$(bao list -format=json pki/keys | jq length)" == 1 ]]
bash "$script_dir/bootstrap-pki.sh" rotate-approle openbao-tls-agent "$test_dir/approle"
test -s "$test_dir/approle/role-id"
test -s "$test_dir/approle/secret-id"
test -s "$test_dir/audit.json"
login="$(bao write -format=json auth/approle/login role_id=@"$test_dir/approle/role-id" \
  secret_id=@"$test_dir/approle/secret-id")"
jq -e '.auth.policies | index("openbao-tls") != null' <<<"$login" >/dev/null
agent_token="$(jq -er '.auth.client_token' <<<"$login")"
BAO_TOKEN="$agent_token" bao read auth/token/lookup-self >/dev/null
BAO_TOKEN="$agent_token" bao write -force auth/token/renew-self >/dev/null
BAO_TOKEN="$agent_token" bao write pki/issue/openbao-server common_name=openbao.home.arpa ip_sans=::1 ttl=1h >/dev/null
if BAO_TOKEN="$agent_token" bao write pki/issue/postgresql-server common_name=postgres.home.arpa ip_sans=::2 ttl=1h >/dev/null 2>&1; then
  echo 'OpenBao agent could issue a PostgreSQL identity' >&2; exit 1
fi
bash "$script_dir/offline-pki.sh" recovery "$test_dir/root.key" "$test_dir/root.crt" "$test_dir/recovery" ::1
openssl verify -CAfile "$test_dir/root.crt" -verify_hostname openbao.home.arpa "$test_dir/recovery/server.crt"
echo 'PASS: offline-signed intermediate, one non-exported CA key, leaf verification, AppRole login, and recovery certificate.'
