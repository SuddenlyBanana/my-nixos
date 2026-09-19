#!/usr/bin/env bash
set -euo pipefail

if (( $# < 2 )); then
  echo "Usage: $0 COMPOSE_FILE OUTPUT_NIX [compose2nix options...]" >&2
  exit 2
fi

compose_file="$(realpath -- "$1")"
output_dir="$(cd -- "$(dirname -- "$2")" && pwd)"
output_file="$output_dir/$(basename -- "$2")"
shift 2

domain1_image_from_secrets=false
compose2nix_args=()
for arg in "$@"; do
  if [[ "$arg" == --domain1-image-from-secrets ]]; then
    domain1_image_from_secrets=true
  else
    compose2nix_args+=("$arg")
  fi
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
compose2nix_path="$(nix build "$repo_root#nixosConfigurations.hadal-abyss-zone.pkgs.compose2nix" --no-link --print-out-paths)"

cd -- "$(dirname -- "$compose_file")"
"$compose2nix_path/bin/compose2nix" \
  -inputs "$(basename -- "$compose_file")" \
  -output "$output_file" \
  -runtime podman \
  -write_nix_setup=false \
  -warnings_as_errors \
  "${compose2nix_args[@]}"

if "$domain1_image_from_secrets"; then
  image_count="$(grep -Ec '^[[:space:]]*image = "ghcr.io/suddenlybanana/www\.[^"]+:main";$' "$output_file" || true)"
  if [[ "$image_count" -ne 1 ]] || ! grep -Fxq '{ pkgs, lib, config, ... }:' "$output_file"; then
    echo "Expected one www image and the compose2nix module header in $output_file" >&2
    exit 1
  fi

  sed -i \
    -e 's/{ pkgs, lib, config, ... }:/{ pkgs, lib, config, secrets, ... }:/' \
    -e 's@image = "ghcr.io/suddenlybanana/www\.[^"]*:main";@image = "ghcr.io/suddenlybanana/www.${secrets.zones.float-play.domain1.name}:main";@' \
    "$output_file"
fi
