switch=/sys/kernel/debug/vgaswitcheroo/switch

# Unlike MIGD, IGD also updates the active GPU and remaps the text consoles.
# Run before the greeter: open DRM clients can refuse a full GPU switch.
printf 'IGD\n' > "$switch"

# The kernel can accept the write even when a client refuses the switch.
if ! grep -q '^[0-9][0-9]*:IGD:+:' "$switch"; then
  echo "select-intel-panel: Intel did not become the active GPU" >&2
  exit 1
fi
