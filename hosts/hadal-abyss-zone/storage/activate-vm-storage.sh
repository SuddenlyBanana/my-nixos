#!/usr/bin/env bash
set -euo pipefail
vgchange -ay --activationmode degraded hadal-vm
# Refuse a partial or accidentally linear layout. Preserve mirroring below
# the cache for data and directly below the thin pool for thin metadata.
test "$(lvs -a --noheadings -o segtype hadal-vm/thinpool_tdata | xargs)" = cache
test "$(lvs -a --noheadings -o segtype hadal-vm/thinpool_tdata_corig | xargs)" = raid1
test "$(lvs -a --noheadings -o segtype hadal-vm/thinpool_tmeta | xargs)" = raid1
test "$(lvs -a --noheadings -o cache_mode hadal-vm/thinpool_tdata | xargs)" = writeback
lvchange --metadataprofile hadal-thin hadal-vm/thinpool
lvchange --monitor y hadal-vm/thinpool
for name in rke2-state postgresql-data openbao-data vaultwarden-data; do
  device="/dev/hadal-vm/$name"
  test -b "$device"
  chgrp kvm "$device"
  chmod 0660 "$device"
done
