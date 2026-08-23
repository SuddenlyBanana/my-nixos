set -eu

efi_variables=/sys/firmware/efi/efivars
gpu_preference="$efi_variables/gpu-power-prefs-fa4ce28d-b62f-4c99-9cc3-6815686e30f9"

if [ ! -d "$efi_variables" ]; then
  echo "prefer-integrated-gpu: EFI variables are unavailable; skipping" >&2
  exit 0
fi

# Apple firmware exposes this variable to Linux but rejects reads with EINVAL.
# Write the complete standard payload: EFI attributes 0x00000007 followed by
# the documented Intel preference byte (1).
chattr -i "$gpu_preference" 2>/dev/null || true
printf '\007\000\000\000\001\000\000\000' > "$gpu_preference"
