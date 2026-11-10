#!/usr/bin/env bash
set -euo pipefail
# Optional test sizes/VG operate only on the three explicit PV arguments.
[[ $# == 3 ]]
pv_a="$1"; pv_b="$2"; pv_cache="$3"
vg="${HADAL_POOL_VG:-hadal-vm}"
data_size="${HADAL_POOL_DATA_SIZE:-700G}"
meta_size="${HADAL_POOL_META_SIZE:-2G}"
cache_size="${HADAL_POOL_CACHE_SIZE:-94G}"
checks="global { thin_check_executable=\"$(command -v thin_check)\" cache_check_executable=\"$(command -v cache_check)\" }"
command -v thin_check >/dev/null
command -v cache_check >/dev/null
run_lvm() {
  local operation="$1"
  shift
  lvm "$operation" --config "$checks" --devices "$pv_a,$pv_b,$pv_cache" "$@"
}
if run_lvm vgs "$vg" >/dev/null 2>&1; then echo 'VG already exists' >&2; exit 1; fi
run_lvm vgcreate "$vg" "$pv_a" "$pv_b" "$pv_cache"
run_lvm lvcreate --type raid1 --mirrors 1 -L "$data_size" -n thinpool "$vg" "$pv_a" "$pv_b"
run_lvm lvcreate --type raid1 --mirrors 1 -L "$meta_size" -n thinmeta "$vg" "$pv_a" "$pv_b"
run_lvm lvcreate --type raid1 --mirrors 1 -L "$meta_size" -n repair-spare "$vg" "$pv_a" "$pv_b"
run_lvm lvconvert --yes --type thin-pool --poolmetadata "$vg/thinmeta" --poolmetadataspare n "$vg/thinpool"
run_lvm lvcreate --type cache-pool -L "$cache_size" --poolmetadataspare n -n vmcache "$vg" "$pv_cache"
run_lvm lvconvert --yes --type cache --cachepool "$vg/vmcache" --cachemode writeback --cachepolicy smq "$vg/thinpool"
run_lvm lvcreate -V 128G --thinpool "$vg/thinpool" -n rke2-state
run_lvm lvcreate -V 128G --thinpool "$vg/thinpool" -n postgresql-data
run_lvm lvcreate -V 32G --thinpool "$vg/thinpool" -n openbao-data
run_lvm lvcreate -V 32G --thinpool "$vg/thinpool" -n vaultwarden-data
# Never place a future mirrored data/metadata extension on the cache PV.
run_lvm pvchange --allocatable n "$pv_cache"
run_lvm lvs -a -o lv_name,segtype,devices,data_percent,metadata_percent,copy_percent "$vg"
