#!/usr/bin/env bash
set -euo pipefail

if [[ "$(findmnt --noheadings --output FSTYPE --target /srv/media)" != "btrfs" ]]; then
  echo "/srv/media is not a mounted Btrfs filesystem" >&2
  exit 1
fi

for service_path in "$@"; do
  if ! btrfs subvolume show "$service_path" >/dev/null; then
    echo "$service_path is not a Btrfs subvolume" >&2
    exit 1
  fi
done
