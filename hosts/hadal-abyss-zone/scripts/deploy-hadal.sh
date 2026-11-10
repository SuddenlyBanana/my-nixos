#!/usr/bin/env bash
set -euo pipefail

# Routine deployment of the running storage-provisioning system, not first-time
# storage setup or promotion to a boot generation. Run on the workstation.
usage() {
  cat <<'EOF'
Usage: bash hosts/hadal-abyss-zone/scripts/deploy-hadal.sh [options]

Build locally, copy to hadal, check the booted kernel, and dry-activate.
The default stops after the preview. --activate also asks for confirmation,
then runs switch-to-configuration test in a detached systemd unit.

  --activate          Offer to activate after reviewing the preview
  --candidate PATH    Reuse a built storage-provisioning system or result link
  --target USER@HOST  SSH destination (default: workspace@172.16.0.241)
  --identity PATH     SSH key (default: ~/.ssh/id_ed25519_personal)
  --help              Show this help

No reboot, system-profile update, boot-loader update, or automatic rollback.
OPNsense configuration remains manual. A test activation can restart VMs;
OpenBao may need manual unsealing. Keep console/OOB access available.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
activate=false
candidate_input=
target=workspace@172.16.0.241
identity="${HOME:?}/.ssh/id_ed25519_personal"
while (($#)); do
  case "$1" in
    --activate) activate=true; shift ;;
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

for command in nix ssh readlink; do
  command -v "$command" >/dev/null || die "Required command not found: $command"
done
[[ "$target" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9_.:-]*$ ]] ||
  die 'Use USER@hostname, USER@IPv4, or USER@unbracketed-IPv6 for --target'
identity="$(readlink -e -- "$identity")" || die 'SSH identity does not exist'
[[ -f "$identity" && -r "$identity" ]] || die 'SSH identity is not a readable file'
# Nix splits NIX_SSHOPTS into arguments. Refuse ambiguous key paths rather than
# silently using different authentication options for nix copy and ssh.
[[ "$identity" =~ ^/[a-zA-Z0-9_./@+-]+$ ]] || die 'SSH key path contains unsupported characters'
ssh_options=(-F /dev/null -i "$identity" -o IdentitiesOnly=yes -o BatchMode=yes
  -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2)
export NIX_SSHOPTS="-F /dev/null -i $identity -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2"

if [[ -z "$candidate_input" ]]; then
  printf 'Building hadal storage-provisioning locally…\n'
  nix build --no-update-lock-file --out-link "$repo_dir/result-hadal-deploy" \
    "$repo_dir#nixosConfigurations.hadal-abyss-zone.config.specialisation.storage-provisioning.configuration.system.build.toplevel"
  candidate_input="$repo_dir/result-hadal-deploy"
fi
candidate="$(readlink -e -- "$candidate_input")" || die 'Candidate does not exist'
[[ "$candidate" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-hadal-abyss-zone-storage-provisioning-[a-zA-Z0-9.+_-]+$ ]] ||
  die 'Candidate must be a hadal storage-provisioning NixOS store path'
[[ -x "$candidate/bin/switch-to-configuration" && -e "$candidate/kernel" ]] ||
  die 'Candidate is not a complete NixOS system'

printf 'Candidate: %s\nTarget: %s\n' "$candidate" "$target"
ssh "${ssh_options[@]}" "$target" bash -s <<'HADAL_IDENTITY'
set -euo pipefail
[[ "$(hostname)" == hadal-abyss-zone ]] || {
  echo 'Wrong target hostname; refusing deployment.' >&2
  exit 1
}
sudo -n true
test -x /run/current-system/sw/bin/flock
HADAL_IDENTITY

copy_target="$target"
if [[ "${target#*@}" == *:* ]]; then
  copy_target="${target%@*}@[${target#*@}]"
fi
nix copy --to "ssh://$copy_target" "$candidate"

ssh "${ssh_options[@]}" "$target" bash -s -- "$candidate" <<'HADAL_PREVIEW'
set -euo pipefail
candidate="$1"
cmp --silent /run/booted-system/kernel "$candidate/kernel" || {
  echo 'STOP: candidate kernel differs from the booted kernel. Plan a separate console-assisted boot.' >&2
  exit 1
}
previous="$(readlink -e /run/current-system)"
printf '\nCurrent runtime: %s\nManual runtime rollback (not a data restore):\n  sudo %s/bin/switch-to-configuration test\n\n' \
  "$previous" "$previous"
sudo -n "$candidate/bin/switch-to-configuration" dry-activate
sudo -n systemctl show microvm@rke2.service microvm@openbao.service microvm@postgresql.service \
  -p Id -p ActiveState -p SubState -p Result -p TimeoutStartUSec
HADAL_PREVIEW

if [[ "$activate" == false ]]; then
  printf '\nPreview only; nothing activated. To activate this exact candidate:\n'
  printf '  bash %q --candidate %q --target %q --identity %q --activate\n' \
    "$repo_dir/hosts/hadal-abyss-zone/scripts/deploy-hadal.sh" "$candidate" "$target" "$identity"
  exit 0
fi

printf '\nReview the unit restarts above. Network access and VMs can be interrupted.\n'
printf 'OpenBao may require manual unsealing. Boot defaults will NOT change.\n'
read -r -p 'Type DEPLOY to test-activate this candidate: ' confirmation || die 'No confirmation received'
[[ "$confirmation" == DEPLOY ]] || die 'Activation cancelled'

unit="hadal-deploy-$(date -u +%Y%m%dT%H%M%SZ)-$$"
printf 'Activation unit: %s.service\n' "$unit"
# PID 1 owns activation so a networkd change or lost workstation connection
# cannot kill the switch halfway through. Keep success/failure state for review.
if ! ssh "${ssh_options[@]}" "$target" bash -s -- "$candidate" "$unit" <<'HADAL_ACTIVATE'
set -euo pipefail
candidate="$1"
unit="$2"
[[ "$(hostname)" == hadal-abyss-zone ]]
cmp --silent /run/booted-system/kernel "$candidate/kernel"
sudo -n systemd-run --unit="$unit" \
  --property=Type=oneshot --property=RemainAfterExit=yes \
  --property=TimeoutStartSec=35min \
  /run/current-system/sw/bin/flock --nonblock /run/lock/hadal-deploy.lock \
  "$candidate/bin/switch-to-configuration" test
HADAL_ACTIVATE
then
  printf 'SSH did not acknowledge activation; checking the named unit before assuming failure.\n' >&2
fi

deadline=$((SECONDS + 2400))
missing=0
last_status=
while ((SECONDS < deadline)); do
  if status="$(ssh "${ssh_options[@]}" "$target" \
    systemctl show "$unit.service" -p LoadState -p ActiveState -p SubState -p Result 2>/dev/null)"; then
    if [[ "$status" != "$last_status" ]]; then
      printf '%s\n' "$status"
      last_status="$status"
    fi
    if [[ "$status" == *LoadState=not-found* ]]; then
      missing=$((missing + 1))
      ((missing < 6)) || die "Activation unit not found. Inspect hadal before retrying: $unit.service"
    elif [[ "$status" == *ActiveState=failed* ]]; then
      ssh "${ssh_options[@]}" "$target" sudo -n journalctl -u "$unit.service" -n 80 --no-pager || true
      die "Activation failed; inspect $unit.service and the previously printed rollback command"
    elif [[ "$status" == *ActiveState=active* && "$status" == *SubState=exited* && "$status" == *Result=success* ]]; then
      break
    fi
  else
    printf 'Waiting for SSH to return; activation continues on hadal (%s.service).\n' "$unit"
  fi
  sleep 5
done
((SECONDS < deadline)) || die "Monitoring timed out; inspect $unit.service. It was not cancelled or rolled back."

ssh "${ssh_options[@]}" "$target" bash -s -- "$candidate" "$unit" <<'HADAL_VERIFY'
set -euo pipefail
[[ "$(readlink -e /run/current-system)" == "$1" ]] || {
  echo 'Runtime does not match the candidate; inspect the activation journal.' >&2
  exit 1
}
sudo -n journalctl -u "$2.service" -n 50 --no-pager
sudo -n systemctl show microvm@rke2.service microvm@openbao.service microvm@postgresql.service \
  -p Id -p ActiveState -p SubState -p Result
printf '\nFailed units (including any pre-existing failures):\n'
systemctl --failed --no-pager
HADAL_VERIFY
printf '\nRuntime activation completed. Review VM/guest health separately.\n'
printf 'The system profile and next boot were not changed. Do not reboot as part of this rollout.\n'
