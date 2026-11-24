#!/usr/bin/env bash
set -euo pipefail
# Drive order is fixed in storage-format.nix; vda is its read-only Nix store.
for pair in vdb:rke2-state vdc:pg-data vdd:openbao-data vde:vault-data; do
  device="/dev/${pair%:*}"
  label="${pair#*:}"
  test -b "$device"
  if blkid -p "$device" >/dev/null 2>&1; then
    [[ "$(blkid -s TYPE -o value "$device")" == xfs ]]
    [[ "$(blkid -s LABEL -o value "$device")" == "$label" ]]
  else
    status=$?
    [[ "$status" == 2 ]]
    # No --force: never overwrite an existing signature.
    mkfs.xfs -L "$label" "$device"
  fi
done
