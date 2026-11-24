#!/usr/bin/env bash
set -euo pipefail

: "${SNAPSHOT_MOUNT:?}"

read -r action
read -r -a quiesce_units <<<"${QUIESCE_UNITS:-}"
state_file="/run/microvm-snapshot-frozen"

case "$action" in
  freeze)
    if [[ -e "$state_file" ]]; then
      echo "ok"
      exit 0
    fi

    printf 'pending\n' >"$state_file"
    if ((${#quiesce_units[@]})); then
      if ! systemctl stop "${quiesce_units[@]}"; then
        rm -f "$state_file"
        echo "error: failed to quiesce ${QUIESCE_UNITS}"
        exit 1
      fi
    fi

    if ! fsfreeze --freeze "$SNAPSHOT_MOUNT"; then
      if ((${#quiesce_units[@]})); then
        systemctl start "${quiesce_units[@]}" || true
      fi
      rm -f "$state_file"
      echo "error: failed to freeze ${SNAPSHOT_MOUNT}"
      exit 1
    fi

    printf 'frozen\n' >"$state_file"
    echo "ok"
    ;;

  thaw)
    if [[ -e "$state_file" ]]; then
      state="$(<"$state_file")"
      if ! fsfreeze --unfreeze "$SNAPSHOT_MOUNT" && [[ "$state" == "frozen" ]]; then
        echo "error: failed to thaw ${SNAPSHOT_MOUNT}"
        exit 1
      fi
      rm -f "$state_file"
    fi

    if ((${#quiesce_units[@]})); then
      if ! systemctl start "${quiesce_units[@]}"; then
        echo "error: filesystem thawed, but failed to resume ${QUIESCE_UNITS}"
        exit 1
      fi
    fi

    echo "ok"
    ;;

  *)
    echo "Unknown action: $action" >&2
    exit 2
    ;;
esac
