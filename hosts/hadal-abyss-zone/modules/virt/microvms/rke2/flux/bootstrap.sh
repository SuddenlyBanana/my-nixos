#!/usr/bin/env bash
set -euo pipefail
umask 077
: "${CREDENTIALS_DIRECTORY:?}" "${RUNTIME_DIRECTORY:?}"
: "${KUBERNETES_API:?}" "${FLUX_COMPONENTS:?}" "${FLUX_SYNC:?}"
: "${POSTGRES_ADDRESS:?}" "${OPENBAO_ADDRESS:?}" "${VAULTWARDEN_HOST:?}"

# Do not edit the shared administrator kubeconfig; use a private temporary
# copy because the API is deliberately bound to the node IPv6, not loopback.
install -m 0600 /etc/rancher/rke2/rke2.yaml "$RUNTIME_DIRECTORY/kubeconfig"
export KUBECONFIG="$RUNTIME_DIRECTORY/kubeconfig"
kubectl config set-cluster default --server="$KUBERNETES_API" >/dev/null
kubectl wait --for=condition=Ready node/hadal-rke2-1 --timeout=5m
kubectl apply --server-side --field-manager=hadal-bootstrap -f "$FLUX_COMPONENTS"
kubectl wait --for=condition=Established --timeout=2m \
  crd/gitrepositories.source.toolkit.fluxcd.io \
  crd/kustomizations.kustomize.toolkit.fluxcd.io

# Never discover host keys with an unauthenticated ssh-keyscan at deployment.
# The independently verified known_hosts and read-only deploy key come from
# agenix; neither these Secrets nor the public root depend on unsealing Bao.
kubectl -n flux-system create secret generic flux-system \
  --from-file=identity="$CREDENTIALS_DIRECTORY/identity" \
  --from-file=known_hosts="$CREDENTIALS_DIRECTORY/known_hosts" \
  --dry-run=client -o yaml | kubectl apply --server-side --field-manager=hadal-bootstrap -f -
kubectl -n flux-system create configmap hadal-runtime \
  --from-literal=POSTGRES_ADDRESS="$POSTGRES_ADDRESS" \
  --from-literal=OPENBAO_ADDRESS="$OPENBAO_ADDRESS" \
  --from-literal=VAULTWARDEN_HOST="$VAULTWARDEN_HOST" \
  --dry-run=client -o yaml | kubectl apply --server-side --field-manager=hadal-bootstrap -f -
kubectl create namespace openbao-system --dry-run=client -o yaml | kubectl apply --server-side --field-manager=hadal-bootstrap -f -
kubectl -n openbao-system create configmap openbao-ca \
  --from-file=ca.crt="$CREDENTIALS_DIRECTORY/ca.crt" \
  --dry-run=client -o yaml | kubectl apply --server-side --field-manager=hadal-bootstrap -f -
kubectl apply --server-side --field-manager=hadal-bootstrap -f "$FLUX_SYNC"
sha256sum "$CREDENTIALS_DIRECTORY/identity" "$CREDENTIALS_DIRECTORY/known_hosts" "$CREDENTIALS_DIRECTORY/ca.crt" \
  | cut -d ' ' -f 1 > /run/hadal-flux-credentials.sha256
