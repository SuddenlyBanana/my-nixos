#!/usr/bin/env bash
set -euo pipefail
part_root="${HADAL_BCACHE_PART_ROOT:-/dev/disk/by-partlabel}"
cache="$part_root/hadal-media-cache"
udevadm wait --timeout=60 "$cache"
cset_uuid="$(bcache-super-show "$cache" | awk '$1 == "cset.uuid" {print $2}')"
[[ "$cset_uuid" =~ ^[0-9a-f-]{36}$ ]]
if [[ ! -d "/sys/fs/bcache/$cset_uuid" ]]; then
  printf '%s\n' "$cache" >/sys/fs/bcache/register
fi
for name in hadal-media-a hadal-media-b; do
  device="$part_root/$name"
  udevadm wait --timeout=60 "$device"
  block="$(basename "$(readlink -f "$device")")"
  if [[ ! -d "/sys/class/block/$block/bcache" ]]; then
    printf '%s\n' "$device" >/sys/fs/bcache/register
  fi
  if [[ ! -e "/sys/class/block/$block/bcache/cache" ]]; then
    printf '%s\n' "$cset_uuid" >"/sys/class/block/$block/bcache/attach"
  fi
  printf 'writeback\n' >"/sys/class/block/$block/bcache/cache_mode"
done
udevadm settle
