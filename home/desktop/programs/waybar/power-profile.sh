#!/usr/bin/env bash

set -euo pipefail

profile="$(tlpctl get 2>/dev/null || true)"

case "${1:-status}" in
  status)
    case "$profile" in
      performance)
        printf '%s\n' '{"text":"󱐋","tooltip":"TLP: Performance","class":"performance"}'
        ;;
      balanced)
        printf '%s\n' '{"text":"󰾅","tooltip":"TLP: Balanced","class":"balanced"}'
        ;;
      power-saver)
        printf '%s\n' '{"text":"󰌪","tooltip":"TLP: Power Saver","class":"power-saver"}'
        ;;
      *)
        printf '%s\n' '{"text":"󰂑","tooltip":"TLP profile unavailable","class":"unavailable"}'
        ;;
    esac
    ;;
  choose)
    selection="$(printf '%s\n' Performance Balanced 'Power Saver' | wofi --dmenu --prompt 'Power profile')"
    case "$selection" in
      Performance) tlpctl set performance ;;
      Balanced) tlpctl set balanced ;;
      "Power Saver") tlpctl set power-saver ;;
      *) exit 0 ;;
    esac
    ;;
  cycle)
    case "$profile" in
      performance) tlpctl set balanced ;;
      balanced) tlpctl set power-saver ;;
      *) tlpctl set performance ;;
    esac
    ;;
esac
