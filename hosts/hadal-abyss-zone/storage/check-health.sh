#!/usr/bin/env bash
set -euo pipefail

report="$(lvs --reportformat json -a -o lv_name,segtype,data_percent,metadata_percent,lv_health_status hadal-vm)"
printf '%s\n' "$report" | jq -e '
  [.report[].lv[] | select(.lv_name == "thinpool")]
  | length == 1
' >/dev/null
printf '%s\n' "$report" | jq -e '
  all(.report[].lv[];
    ((.data_percent | tonumber? // 0) < 80) and
    ((.metadata_percent | tonumber? // 0) < 70) and
    ((.lv_health_status | gsub(" "; "")) == ""))
' >/dev/null || {
  echo 'Hadal storage degraded or thin-pool data/metadata threshold exceeded' >&2
  printf '%s\n' "$report" >&2
  exit 1
}
