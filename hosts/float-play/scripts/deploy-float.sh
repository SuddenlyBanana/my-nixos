#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash hosts/float-play/scripts/deploy-float.sh [options]

Build locally, copy to float-play, check the booted kernel, and dry-activate.
The default stops after the preview. Activation runs in a detached systemd unit.

  --activate          Ask to test-activate the previewed candidate (runtime only)
  --persist           Ask to persist an already-running --candidate for next boot
  --candidate PATH    Reuse a built float-play system or result link
  --target USER@HOST  SSH destination (default: workspace@64.176.71.121)
  --identity PATH     SSH key (default: ~/.ssh/id_ed25519_personal)
  --help              Show this help

--activate and --persist are separate operations. --persist requires --candidate
and refuses unless that exact candidate is the healthy current runtime.
No reboot or automatic rollback. Always builds on the workstation, never the VPS.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
mode=preview
candidate_input=
target=workspace@64.176.71.121
identity="${HOME:?}/.ssh/id_ed25519_personal"
while (($#)); do
  case "$1" in
    --activate|--persist)
      [[ "$mode" == preview ]] || die 'Choose only one of --activate and --persist'
      if [[ "$1" == --activate ]]; then mode="test"; else mode=persist; fi
      shift ;;
    --candidate|--target|--identity)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || die "$1 needs a value"
      case "$1" in
        --candidate) candidate_input="$2" ;;
        --target) target="$2" ;;
        --identity) identity="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done
[[ "$mode" != persist || -n "$candidate_input" ]] || die '--persist requires --candidate'

for command in nix ssh readlink; do
  command -v "$command" >/dev/null || die "Required command not found: $command"
done
[[ "$target" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9_.:-]*$ ]] ||
  die 'Use USER@hostname, USER@IPv4, or USER@unbracketed-IPv6 for --target'
identity="$(readlink -e -- "$identity")" || die 'SSH identity does not exist'
[[ -f "$identity" && -r "$identity" ]] || die 'SSH identity is not a readable file'
# Nix splits NIX_SSHOPTS into words, so refuse ambiguous identity paths.
[[ "$identity" =~ ^/[a-zA-Z0-9_./@+-]+$ ]] || die 'SSH key path contains unsupported characters'
ssh_options=(-F /dev/null -i "$identity" -o IdentitiesOnly=yes -o BatchMode=yes
  -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2)
export NIX_SSHOPTS="-F /dev/null -i $identity -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2"

if [[ -z "$candidate_input" ]]; then
  printf 'Building float-play locally…\n'
  nix build --no-update-lock-file --out-link "$repo_dir/result-float-deploy" \
    "$repo_dir#nixosConfigurations.float-play.config.system.build.toplevel"
  candidate_input="$repo_dir/result-float-deploy"
fi
candidate="$(readlink -e -- "$candidate_input")" || die 'Candidate does not exist'
[[ "$candidate" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-float-play-[a-zA-Z0-9.+_-]+$ ]] ||
  die 'Candidate must be a float-play NixOS store path'
[[ -x "$candidate/bin/switch-to-configuration" && -e "$candidate/kernel" ]] ||
  die 'Candidate is not a complete NixOS system'

printf 'Candidate: %s\nTarget: %s\n' "$candidate" "$target"
ssh "${ssh_options[@]}" "$target" bash -s <<'FLOAT_IDENTITY'
set -euo pipefail
[[ "$(hostname)" == float-play ]] || { echo 'Wrong target hostname; refusing deployment.' >&2; exit 1; }
sudo -n true
test -x /run/current-system/sw/bin/flock
FLOAT_IDENTITY

copy_target="$target"
if [[ "${target#*@}" == *:* ]]; then copy_target="${target%@*}@[${target#*@}]"; fi
# workspace is trusted by the remote daemon. Local closures are unsigned;
# disable signature checks for this authenticated copy, not daemon-wide.
nix copy --no-check-sigs --to "ssh-ng://$copy_target" "$candidate"

ssh "${ssh_options[@]}" "$target" bash -s -- "$candidate" "$mode" <<'FLOAT_PREVIEW'
set -euo pipefail
candidate="$1"
cmp --silent /run/booted-system/kernel "$candidate/kernel" || {
  echo 'STOP: candidate kernel differs from the booted kernel. Plan a separate console-assisted boot.' >&2
  exit 1
}
previous="$(readlink -e /run/current-system)"
profile="$(readlink -e /nix/var/nix/profiles/system)"
printf '\nCurrent runtime: %s\nCurrent system profile: %s\n' "$previous" "$profile"
printf 'Manual runtime rollback (not a data restore):\n  sudo %s/bin/switch-to-configuration test\n' "$previous"
printf 'Manual profile/boot restore if persistence fails:\n  sudo nix-env --profile /nix/var/nix/profiles/system --set %s\n  sudo %s/bin/switch-to-configuration boot\n\n' "$profile" "$profile"
if [[ "$2" == persist ]]; then
  [[ "$previous" == "$candidate" ]] || { echo 'Test-activate this exact candidate before persisting it.' >&2; exit 1; }
fi
sudo -n "$candidate/bin/switch-to-configuration" dry-activate
FLOAT_PREVIEW

candidate_command() {
  printf '  bash %q --candidate %q --target %q --identity %q %s\n' \
    "$repo_dir/hosts/float-play/scripts/deploy-float.sh" "$candidate" "$target" "$identity" "$1"
}
if [[ "$mode" == preview ]]; then
  printf '\nPreview only; nothing activated. To test-activate this exact candidate:\n'
  candidate_command --activate
  exit 0
fi

if [[ "$mode" == test ]]; then
  printf '\nReview the unit restarts above. Network access and proxied services can be interrupted.\n'
  read -r -p 'Type DEPLOY to test-activate this candidate: ' confirmation || die 'No confirmation received'
  [[ "$confirmation" == DEPLOY ]] || die 'Activation cancelled'
else
  printf '\nThis updates the system profile and boot entries for the tested runtime, without rebooting.\n'
  read -r -p 'Type PERSIST to make this candidate the boot default: ' confirmation || die 'No confirmation received'
  [[ "$confirmation" == PERSIST ]] || die 'Persistence cancelled'
fi

unit="float-deploy-$mode-$(date -u +%Y%m%dT%H%M%SZ)-$$"
printf 'Deployment unit: %s.service\n' "$unit"
if ! ssh "${ssh_options[@]}" "$target" bash -s -- "$candidate" "$unit" "$mode" <<'FLOAT_ACTIVATE'
set -euo pipefail
candidate="$1"
unit="$2"
mode="$3"
[[ "$(hostname)" == float-play ]]
# PID 1 owns this operation. Guards run again under the deployment lock so
# concurrent deploys cannot change runtime between checking it and persistence.
# Pass shell variables verbatim through systemd and supply NixOS executable
# paths explicitly; transient units do not inherit the SSH login environment.
sudo -n systemd-run --unit="$unit" \
  --expand-environment=no \
  --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin \
  --property=Type=oneshot --property=RemainAfterExit=yes \
  --property=TimeoutStartSec=15min \
  /run/current-system/sw/bin/flock --nonblock /run/lock/float-deploy.lock \
  /run/current-system/sw/bin/bash -c '
set -euo pipefail
candidate="$1"
mode="$2"
[[ "$(hostname)" == float-play ]]
cmp --silent /run/booted-system/kernel "$candidate/kernel" || {
  echo "Booted kernel changed; refusing deployment." >&2; exit 1;
}
case "$mode" in
  test) "$candidate/bin/switch-to-configuration" test ;;
  persist)
    [[ "$(readlink -e /run/current-system)" == "$candidate" ]] || {
      echo "Runtime changed; refusing to persist an untested candidate." >&2; exit 1;
    }
    services=(systemd-networkd sshd firewall nginx knot)
    for service in postfix postfix-network-ready jool-nat64-hadal; do
      if [[ -e "$candidate/etc/systemd/system/$service.service" ]]; then
        services+=("$service")
      fi
    done
    for service in "${services[@]}"; do
      systemctl is-active --quiet "$service.service" || {
        echo "Service is not active: $service.service" >&2; exit 1;
      }
    done
    /run/current-system/sw/bin/nix-env --profile /nix/var/nix/profiles/system --set "$candidate"
    "$candidate/bin/switch-to-configuration" boot
    ;;
  *) exit 1 ;;
esac
' -- "$candidate" "$mode"
FLOAT_ACTIVATE
then
  printf 'SSH did not acknowledge deployment; checking the named unit before assuming failure.\n' >&2
fi

deadline=$((SECONDS + 1000))
missing=0
last_status=
while ((SECONDS < deadline)); do
  if status="$(ssh "${ssh_options[@]}" "$target" \
    systemctl show "$unit.service" -p LoadState -p ActiveState -p SubState -p Result 2>/dev/null)"; then
    if [[ "$status" != "$last_status" ]]; then printf '%s\n' "$status"; last_status="$status"; fi
    if [[ "$status" == *LoadState=not-found* ]]; then
      missing=$((missing + 1))
      ((missing < 6)) || die "Deployment unit not found. Inspect float-play before retrying: $unit.service"
    elif [[ "$status" == *ActiveState=failed* ]]; then
      ssh "${ssh_options[@]}" "$target" sudo -n journalctl -u "$unit.service" -n 80 --no-pager || true
      die "Deployment failed. Inspect $unit.service and the printed rollback commands; persistence may be partial."
    elif [[ "$status" == *ActiveState=active* && "$status" == *SubState=exited* && "$status" == *Result=success* ]]; then
      break
    fi
  else
    printf 'Waiting for SSH to return; deployment continues on float-play (%s.service).\n' "$unit"
  fi
  sleep 5
done
((SECONDS < deadline)) || die "Monitoring timed out; inspect $unit.service. It was not cancelled or rolled back."

ssh "${ssh_options[@]}" "$target" bash -s -- "$candidate" "$unit" "$mode" <<'FLOAT_VERIFY'
set -euo pipefail
candidate="$1"
[[ "$(hostname)" == float-play ]]
[[ "$(readlink -e /run/current-system)" == "$candidate" ]] || {
  echo 'Runtime does not match the candidate; inspect the deployment journal.' >&2; exit 1;
}
if [[ "$3" == persist ]]; then
  [[ "$(readlink -e /nix/var/nix/profiles/system)" == "$candidate" ]] || {
    echo 'System profile does not match the candidate; inspect persistence before rebooting.' >&2; exit 1;
  }
fi
sudo -n journalctl -u "$2.service" -n 50 --no-pager
services=(systemd-networkd sshd firewall nginx knot)
for service in postfix postfix-network-ready jool-nat64-hadal; do
  if [[ -e "$candidate/etc/systemd/system/$service.service" ]]; then
    services+=("$service")
  fi
done
for service in "${services[@]}"; do
  systemctl show "$service.service" -p Id -p ActiveState -p SubState -p Result
  systemctl is-active --quiet "$service.service" || {
    echo "Service is not active: $service.service" >&2; exit 1;
  }
done
printf '\nFailed units (including any pre-existing failures):\n'
systemctl --failed --no-pager
FLOAT_VERIFY

if [[ "$mode" == test ]]; then
  printf '\nRuntime activation completed. The system profile and boot default were not changed.\n'
  printf 'After checking public DNS, mail and tunnel traffic, persist this exact candidate with:\n'
  candidate_command --persist
else
  printf '\nTested runtime persisted to the system profile and boot configuration. No reboot performed.\n'
fi
