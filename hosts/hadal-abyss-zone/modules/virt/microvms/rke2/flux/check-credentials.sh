#!/usr/bin/env bash
set -euo pipefail

# A failed bootstrap already retries with fresh systemd credentials. Do not
# interrupt an in-progress install; restart a successful one only on changes.
systemctl is-active --quiet hadal-flux-bootstrap.service || exit 0
for name in flux-ssh-key flux-known-hosts ca.crt; do
  test -s "/run/hadal-bootstrap/$name" || exit 1
done
digest="$(sha256sum /run/hadal-bootstrap/flux-ssh-key /run/hadal-bootstrap/flux-known-hosts /run/hadal-bootstrap/ca.crt | cut -d ' ' -f 1)"
state=/run/hadal-flux-credentials.sha256
if [[ ! -f "$state" ]] || [[ "$digest" != "$(< "$state")" ]]; then
  systemctl restart hadal-flux-bootstrap.service
fi
