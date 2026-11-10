#!/usr/bin/env bash
set -euo pipefail
: "${BACKUP_MOUNT:?}" "${EXPECTED_NFS_DEVICE:?}"
# Looking up the marker deliberately triggers the automount first.
test "$(cat "$BACKUP_MOUNT/.hadal-backup-target")" = hadal-backup-v1
mountpoint -q "$BACKUP_MOUNT"
findmnt --noheadings --output FSTYPE --mountpoint "$BACKUP_MOUNT" | grep -Eq '^nfs4?$'
test "$(findmnt --noheadings --output SOURCE --mountpoint "$BACKUP_MOUNT")" = "$EXPECTED_NFS_DEVICE"
