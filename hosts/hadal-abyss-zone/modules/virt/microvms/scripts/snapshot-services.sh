#!/usr/bin/env bash
set -euo pipefail

: "${SERVICE_ROOT:?}"
: "${SNAPSHOT_ROOT:?}"
: "${RETENTION_DAYS:?}"
: "${FREEZE_TIMEOUT:?}"
: "${CONTROL_PORT:?}"

if (($# == 0)); then
  echo "At least one service name is required" >&2
  exit 2
fi

frozen_services=()
declare -A service_addresses=()
services=()
snapshot_complete=false

for service_spec in "$@"; do
  service="${service_spec%%@*}"
  address="${service_spec#*@}"
  if [[ -z "$service" || -z "$address" || "$service" == "$address" ]]; then
    echo "Invalid service specification: ${service_spec}" >&2
    exit 2
  fi
  services+=("$service")
  service_addresses["$service"]="$address"
done

request_control() {
  local service="$1"
  local action="$2"
  local response

  response="$(
    printf '%s\n' "$action" \
      | nc -6 -w "$FREEZE_TIMEOUT" "${service_addresses[$service]}" "$CONTROL_PORT"
  )"
  if [[ "$response" != "ok" ]]; then
    echo "${service}: ${action} failed: ${response:-no response}" >&2
    return 1
  fi
}

thaw_services() {
  local index service
  local thaw_failed=false

  for ((index = ${#frozen_services[@]} - 1; index >= 0; index--)); do
    service="${frozen_services[index]}"
    if ! request_control "$service" thaw; then
      echo "${service}: filesystem may still be frozen" >&2
      thaw_failed=true
    fi
  done

  if [[ "$thaw_failed" == true ]]; then
    return 1
  fi
}

cleanup() {
  local exit_status=$?
  if ((${#frozen_services[@]})); then
    if ! thaw_services; then
      exit_status=1
    fi
  fi
  if [[ "$snapshot_complete" == false && $exit_status -eq 0 ]]; then
    exit_status=1
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

for service in "${services[@]}"; do
  source_path="${SERVICE_ROOT}/${service}"

  btrfs subvolume show "$source_path" >/dev/null
  install -d -m 0700 "${SNAPSHOT_ROOT}/${service}"

  if systemctl is-active --quiet "microvm@${service}.service"; then
    # Record the guest before sending the request: if the response is lost
    # after the guest freezes, the EXIT trap must still attempt a thaw.
    frozen_services+=("$service")
    if request_control "$service" freeze; then
      :
    elif systemctl is-active --quiet "microvm@${service}.service"; then
      exit 1
    else
      unset 'frozen_services[-1]'
      echo "${service}: guest stopped during freeze; snapshotting the closed image" >&2
    fi
  fi
done

timestamp="$(date --utc +%Y%m%dT%H%M%SZ)"
for service in "${services[@]}"; do
  source_path="${SERVICE_ROOT}/${service}"
  image_path="${source_path}/data.raw"
  snapshot_path="${SNAPSHOT_ROOT}/${service}/${timestamp}"

  if [[ -e "$image_path" ]]; then
    sync "$image_path"
  fi
  btrfs subvolume snapshot -r "$source_path" "$snapshot_path"
done

snapshot_complete=true
thaw_services
frozen_services=()

for service in "${services[@]}"; do
  while IFS= read -r -d '' old_snapshot; do
    btrfs subvolume delete -- "$old_snapshot"
  done < <(
    find "${SNAPSHOT_ROOT}/${service}" \
      -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -print0
  )
done
