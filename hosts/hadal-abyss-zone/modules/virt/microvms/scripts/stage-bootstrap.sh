#!/usr/bin/env bash
set -euo pipefail
: "${BOOTSTRAP_VM:?}"

destination="/run/hadal-bootstrap/$BOOTSTRAP_VM"
install -d -m 0750 -o root -g kvm "$destination"

copy_secret() {
  local source="/run/agenix/hadal-bootstrap-$1"
  local target="$destination/$2"
  if [[ -s "$source" ]]; then
    install -m 0400 -o root -g root "$source" "$target.new"
    mv -f "$target.new" "$target"
  elif [[ "${3:-required}" == required ]]; then
    printf 'Missing agenix bootstrap input: %s\n' "$source" >&2
    exit 1
  else
    rm -f "$target"
  fi
}

case "$BOOTSTRAP_VM" in
  openbao)
    copy_secret ca-cert ca.crt
    copy_secret openbao-recovery-cert server.crt
    copy_secret openbao-recovery-key server.key
    # First boot must allow init/unseal and the offline intermediate ceremony.
    copy_secret openbao-role-id role-id optional
    copy_secret openbao-secret-id secret-id optional
    copy_secret restic-password restic-password optional
    copy_secret backup-role-id backup-role-id optional
    copy_secret backup-secret-id backup-secret-id optional
    ;;
  postgresql)
    copy_secret ca-cert ca.crt
    copy_secret postgresql-role-id role-id
    copy_secret postgresql-secret-id secret-id
    copy_secret pgbackrest-pass pgbackrest-pass optional
    ;;
  rke2)
    copy_secret rke2-token token
    copy_secret ca-cert ca.crt optional
    copy_secret flux-ssh-key flux-ssh-key optional
    copy_secret flux-known-hosts flux-known-hosts optional
    copy_secret restic-password restic-password optional
    ;;
  *) exit 2 ;;
esac
