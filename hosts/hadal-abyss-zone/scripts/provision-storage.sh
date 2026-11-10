#!/usr/bin/env bash
set -euo pipefail

# Explicit operator action only. Never called by NixOS activation or a unit.
readonly vm_a=/dev/disk/by-id/wwn-0x5000c5002d4b2546
readonly large=/dev/disk/by-id/wwn-0x5000c50065b35f96
readonly media_a=/dev/disk/by-id/wwn-0x50024e9204309cb2
readonly cache=/dev/disk/by-id/nvme-eui.0025388191be451d
readonly part=/dev/disk/by-partlabel

case "${1:-plan}" in
  plan)
    cat <<'EOF'
Hadal storage (all sizes binary):
  HDD A 930 GiB + large HDD part 1 930 GiB: encrypted PVs, LVM RAID1.
  RAID1 700 GiB thin data + RAID1 2 GiB thin metadata + 2 GiB repair spare.
  NVMe part 1 96 GiB: encrypted PV, 94 GiB dm-cache in writeback mode.
  large HDD part 2 + HDD C 930 GiB: bcache, then LUKS, then Btrfs RAID1.
  NVMe part 2: one shared bcache cache set, writeback mode.
  VG hadal-vm, pool thinpool; thin LVs 128G/128G/32G/32G.

Commands: partition | create-vm-pool | create-media
Every command requires --confirm DESTROY-HADAL-STORAGE.
partition additionally requires BACKUP_DIR on independent/system storage.
Storage keys come from /run/agenix/hadal-bootstrap-{vm,media}-storage-key.
EOF
    exit 0 ;;
  partition|create-vm-pool|create-media) operation="$1" ;;
  *) exit 2 ;;
esac
[[ "${2:-}" == --confirm && "${3:-}" == DESTROY-HADAL-STORAGE && $# == 3 ]]
((EUID == 0))
umask 077

assert_idle() {
  local node="$1" child
  test -b "$node"
  if lsblk -nrpo MOUNTPOINTS "$node" | grep -Eq '[^[:space:]]'; then
    echo "Mounted target: $node" >&2; exit 1
  fi
  while read -r child; do
    if compgen -G "/sys/class/block/$(basename "$child")/holders/*" >/dev/null; then
      echo "Target has active holders: $child" >&2; exit 1
    fi
  done < <(lsblk -nrpo NAME "$node")
}

assert_blank() {
  local status=0
  blkid -p "$1" || status=$?
  if [[ "$status" != 2 ]]; then
    echo "Cannot prove $1 is blank (blkid status $status); refusing initialization" >&2
    exit 1
  fi
}

case "$operation" in
  partition)
    : "${BACKUP_DIR:?Set BACKUP_DIR to independent/system storage}"
    [[ "$BACKUP_DIR" == /* && "$BACKUP_DIR" != /srv/media && "$BACKUP_DIR" != /srv/media/* ]]
    # Every identity must resolve to a distinct disk of the expected class.
    declare -A seen=()
    for specification in "$vm_a:900:1100" "$large:1800:2200" "$media_a:900:1100" "$cache:200:300"; do
      disk="${specification%%:*}"
      limits="${specification#*:}"
      resolved="$(readlink -e "$disk")"
      [[ "$(lsblk -dnro TYPE "$resolved")" == disk && ! -v "seen[$resolved]" ]]
      seen["$resolved"]=1
      size="$(blockdev --getsize64 "$resolved")"
      ((size >= ${limits%:*} * 1000000000 && size <= ${limits#*:} * 1000000000))
      assert_idle "$resolved"
    done
    install -d -m 0700 "$BACKUP_DIR"
    lsblk -p -o NAME,SIZE,FSTYPE,UUID,PARTUUID,MODEL,SERIAL,WWN,MOUNTPOINTS >"$BACKUP_DIR/lsblk.txt"
    for disk in "$vm_a" "$large" "$media_a" "$cache"; do
      name="$(basename "$disk")"
      test ! -e "$BACKUP_DIR/$name.gpt"
      sgdisk --backup="$BACKUP_DIR/$name.gpt" "$disk"
    done
    sgdisk --zap-all "$vm_a"
    sgdisk --clear --align-end -n 1:0:+930G -t 1:8309 -c 1:hadal-vm-a "$vm_a"
    sgdisk --zap-all "$large"
    sgdisk --clear --align-end -n 1:0:+930G -t 1:8309 -c 1:hadal-vm-b \
      -n 2:0:0 -t 2:8300 -c 2:hadal-media-b "$large"
    sgdisk --zap-all "$media_a"
    sgdisk --clear --align-end -n 1:0:+930G -t 1:8300 -c 1:hadal-media-a "$media_a"
    sgdisk --zap-all "$cache"
    sgdisk --clear --align-end -n 1:0:+96G -t 1:8309 -c 1:hadal-vm-cache \
      -n 2:0:0 -t 2:8300 -c 2:hadal-media-cache "$cache"
    partprobe "$vm_a" "$large" "$media_a" "$cache"
    udevadm settle
    for name in hadal-vm-a hadal-vm-b hadal-vm-cache hadal-media-a hadal-media-b hadal-media-cache; do
      wipefs --all --force "$part/$name"
    done
    ;;
  create-vm-pool)
    key=/run/agenix/hadal-bootstrap-vm-storage-key
    test -s "$key"
    if vgs hadal-vm >/dev/null 2>&1; then echo 'VG already exists; refusing reinitialization' >&2; exit 1; fi
    for name in hadal-vm-a hadal-vm-b hadal-vm-cache; do
      assert_idle "$part/$name"
      assert_blank "$part/$name"
    done
    for name in hadal-vm-a hadal-vm-b hadal-vm-cache; do
      cryptsetup luksFormat --type luks2 --label "$name" --key-file "$key" "$part/$name"
      cryptsetup open --key-file "$key" "$part/$name" "$name"
      pvcreate "/dev/mapper/$name"
    done
    bash "$(dirname "$(readlink -f "$0")")/../storage/create-vm-pool.sh" \
      /dev/mapper/hadal-vm-a /dev/mapper/hadal-vm-b /dev/mapper/hadal-vm-cache
    echo 'Wait for both RAID1 LVs to finish syncing, then run the storage-format MicroVM.'
    ;;
  create-media)
    key=/run/agenix/hadal-bootstrap-media-storage-key
    test -s "$key"
    for name in hadal-media-a hadal-media-b hadal-media-cache; do
      assert_idle "$part/$name"
      assert_blank "$part/$name"
    done
    test ! -e /dev/mapper/media0
    test ! -e /dev/mapper/media1
    make-bcache -C "$part/hadal-media-cache"
    make-bcache -B "$part/hadal-media-a"
    make-bcache -B "$part/hadal-media-b"
    systemctl restart hadal-bcache.service
    for pair in hadal-media-a:media0 hadal-media-b:media1; do
      name="${pair%:*}"
      backing="$(basename "$(readlink -f "$part/$name")")"
      bcache="$(readlink -f "/sys/class/block/$backing/bcache/dev")"
      bcache="/dev/$(basename "$bcache")"
      test -b "$bcache"
      cryptsetup luksFormat --type luks2 --label "$name" --key-file "$key" "$bcache"
      cryptsetup open --key-file "$key" "$bcache" "${pair#*:}"
    done
    mkfs.btrfs --data raid1 --metadata raid1 --label hadal-media /dev/mapper/media0 /dev/mapper/media1
    ;;
esac
