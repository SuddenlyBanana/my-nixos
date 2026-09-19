#!/usr/bin/env bash
set -euo pipefail

container_user="${CONTAINER_UPDATE_USER:?}"
image="${CONTAINER_UPDATE_IMAGE:?}"
service="${CONTAINER_UPDATE_SERVICE:?}"
container="${CONTAINER_UPDATE_NAME:?}"

# A timer must not start a container that was intentionally stopped.
if ! systemctl is-active --quiet "$service"; then
  exit 0
fi

podman_for_container() {
  if [[ "$container_user" == root ]]; then
    podman "$@"
  else
    runtime_dir="/run/user/$(id -u "$container_user")"
    runuser -u "$container_user" -- env XDG_RUNTIME_DIR="$runtime_dir" podman "$@"
  fi
}

running_image="$(podman_for_container container inspect --format '{{.Image}}' "$container" 2>/dev/null || true)"
podman_for_container pull "$image"
latest_image="$(podman_for_container image inspect --format '{{.Id}}' "$image")"

if [[ "$running_image" != "$latest_image" ]]; then
  systemctl restart "$service"
fi
