#!/usr/bin/env bash
set -euo pipefail
((EUID == 0))
script_dir="$(dirname "$(readlink -f "$0")")"
test_dir="$(mktemp -d /tmp/hadal-lvm-test.XXXXXX)"
vg="hadal-test-$$"
loops=()
cleanup() {
  if mountpoint -q "$test_dir/mount"; then umount "$test_dir/mount"; fi
  if ((${#loops[@]} == 3)); then
    lvchange --devices "${loops[0]},${loops[1]},${loops[2]}" -an "$vg" 2>/dev/null || true
    vgremove --devices "${loops[0]},${loops[1]},${loops[2]}" --yes "$vg" 2>/dev/null || true
  fi
  for device in "${loops[@]}"; do
    # Only detach devices whose backing file is still in this test directory.
    case "$(losetup -n -O BACK-FILE "$device")" in "$test_dir"/*) losetup -d "$device" ;; esac
  done
  rm -rf "$test_dir"
}
trap cleanup EXIT
for name in a b cache; do
  truncate -s 4G "$test_dir/$name.img"
  loops+=("$(losetup --find --show "$test_dir/$name.img")")
done
pvcreate --devices "${loops[0]},${loops[1]},${loops[2]}" "${loops[@]}"
export HADAL_POOL_VG="$vg" HADAL_POOL_DATA_SIZE=1G HADAL_POOL_META_SIZE=32M HADAL_POOL_CACHE_SIZE=128M
checks="global { thin_check_executable=\"$(command -v thin_check)\" cache_check_executable=\"$(command -v cache_check)\" }"
bash "$script_dir/create-vm-pool.sh" "${loops[@]}"
for specification in thinpool_tdata:cache thinpool_tdata_corig:raid1 thinpool_tmeta:raid1; do
  actual="$(lvs --devices "${loops[0]},${loops[1]},${loops[2]}" -a --noheadings -o segtype "$vg/${specification%:*}" | xargs)"
  [[ "$actual" == "${specification#*:}" ]]
done
mkfs.xfs -q -L test-data "/dev/$vg/rke2-state"
install -d "$test_dir/mount"
mount "/dev/$vg/rke2-state" "$test_dir/mount"
printf 'survives activation\n' >"$test_dir/mount/probe"
umount "$test_dir/mount"
lvchange --config "$checks" --devices "${loops[0]},${loops[1]},${loops[2]}" -an "$vg"
vgchange --config "$checks" --devices "${loops[0]},${loops[1]},${loops[2]}" -ay "$vg"
mount "/dev/$vg/rke2-state" "$test_dir/mount"
test "$(cat "$test_dir/mount/probe")" = 'survives activation'
umount "$test_dir/mount"
echo 'PASS: mirrored thin data and metadata, dm-cache writeback, XFS I/O and reactivation.'
