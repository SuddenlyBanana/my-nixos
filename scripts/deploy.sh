#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh HOSTNAME [options]

Build locally, copy to the host, check the booted kernel, and preview activation.
Supported hosts: float-play, hadal-abyss-zone.

  --activate          Ask to activate the previewed system for this boot
  --persist           Ask to make a running --candidate the next boot default
  --provisioning      Select Hadal's manual-start storage-provisioning profile
  --candidate PATH    Reuse a built system or result link
  --target USER@HOST  Override the SSH destination
  --identity PATH     Override the SSH key (~/.ssh/id_ed25519_personal)
  --help              Show this help

Both hosts default to their normal profile.
Persistence requires the normal profile on Hadal and the exact candidate to be
running with its required services active. Activation and persistence are
separate operations. The script does not reboot or automatically roll back.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

host="${1:-}"
case "$host" in
  --help|-h) usage; exit 0 ;;
  float-play)
    target=workspace@64.176.71.121
    result_link=result-float-deploy
    copy_transport=ssh-ng
    copy_options=(--no-check-sigs)
    unit_prefix=float-deploy
    activation_timeout=15min
    monitoring_timeout=1000
    ;;
  hadal-abyss-zone)
    target=workspace@172.16.0.241
    result_link=result-hadal-normal-deploy
    copy_transport=ssh
    copy_options=()
    unit_prefix=hadal-deploy
    activation_timeout=35min
    monitoring_timeout=2400
    ;;
  '') usage >&2; exit 2 ;;
  *) die "Unknown deployment host: $host" ;;
esac
shift

mode=preview
profile=normal
candidate_input=
identity="${HOME:?}/.ssh/id_ed25519_personal"
while (($#)); do
  case "$1" in
    --activate|--persist)
      [[ "$mode" == preview ]] || die 'Choose only one of --activate and --persist'
      if [[ "$1" == --activate ]]; then mode="test"; else mode=persist; fi
      shift
      ;;
    --provisioning)
      [[ "$host" == hadal-abyss-zone ]] || die '--provisioning applies only to hadal-abyss-zone'
      profile=storage-provisioning
      shift
      ;;
    --candidate|--target|--identity)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || die "$1 needs a value"
      case "$1" in
        --candidate) candidate_input="$2" ;;
        --target) target="$2" ;;
        --identity) identity="$2" ;;
      esac
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done
if [[ "$mode" == persist ]]; then
  [[ "$profile" == normal ]] || die '--persist requires the normal profile'
  [[ -n "$candidate_input" ]] || die '--persist requires --candidate'
fi

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
build_attr="nixosConfigurations.$host.config.system.build.toplevel"
candidate_label="$host"
candidate_version='[a-zA-Z0-9.+_-]+'
if [[ "$profile" == storage-provisioning ]]; then
  result_link=result-hadal-deploy
  build_attr="nixosConfigurations.$host.config.specialisation.storage-provisioning.configuration.system.build.toplevel"
  candidate_label="$host-$profile"
elif [[ "$host" == hadal-abyss-zone ]]; then
  candidate_version='[0-9][a-zA-Z0-9.+_-]*'
fi

for command in nix ssh readlink; do
  command -v "$command" >/dev/null || die "Required command not found: $command"
done
[[ "$target" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9_.:-]*$ ]] ||
  die 'Use USER@hostname, USER@IPv4, or USER@unbracketed-IPv6 for --target'
identity="$(readlink -e -- "$identity")" || die 'SSH identity does not exist'
[[ -f "$identity" && -r "$identity" ]] || die 'SSH identity is not a readable file'
# Nix splits NIX_SSHOPTS into words.
[[ "$identity" =~ ^/[a-zA-Z0-9_./@+-]+$ ]] || die 'SSH identity path contains unsupported characters'
ssh_options=(-F /dev/null -i "$identity" -o IdentitiesOnly=yes -o BatchMode=yes
  -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2)
export NIX_SSHOPTS="-F /dev/null -i $identity -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2"

if [[ -z "$candidate_input" ]]; then
  printf 'Building %s (%s profile) locally…\n' "$host" "$profile"
  candidate_input="$repo_dir/$result_link"
  nix build --no-update-lock-file --out-link "$candidate_input" "$repo_dir#$build_attr"
fi
candidate="$(readlink -e -- "$candidate_input")" || die 'Candidate does not exist'
[[ "$candidate" =~ ^/nix/store/[a-z0-9]{32}-nixos-system-${candidate_label}-${candidate_version}$ ]] ||
  die "Candidate must be a $host NixOS store path for the $profile profile"
[[ -x "$candidate/bin/switch-to-configuration" && -e "$candidate/kernel" ]] ||
  die 'Candidate is not a complete NixOS system'

remote_script="$(cat <<'REMOTE'
set -euo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

check_host() {
  [[ "$(hostname)" == "$1" ]] || die "Wrong target hostname; expected $1"
}

check_kernel() {
  cmp --silent /run/booted-system/kernel "$1/kernel" ||
    die 'Candidate kernel differs from the booted kernel. Plan a separate console-assisted boot.'
}

check_running() {
  [[ "$(readlink -e /run/current-system)" == "$1" ]] ||
    die 'Runtime does not match the candidate. Test-activate this exact candidate first.'
}

check_services() {
  local host="$1" candidate="$2" detail="$3" service
  local -a services=(systemd-networkd.service sshd.service firewall.service)
  case "$host" in
    float-play)
      services+=(nginx.service knot.service)
      for service in postfix.service postfix-network-ready.service jool-nat64-hadal.service; do
        if [[ -e "$candidate/etc/systemd/system/$service" ]]; then services+=("$service"); fi
      done
      ;;
    hadal-abyss-zone)
      services+=(hadal-vm-storage.service srv-media.mount
        microvm@rke2.service microvm@openbao.service microvm@postgresql.service)
      ;;
  esac
  for service in "${services[@]}"; do
    if [[ "$detail" == show ]]; then
      systemctl show "$service" -p Id -p ActiveState -p SubState -p Result
    fi
    systemctl is-active --quiet "$service" || die "Service or mount is not active: $service"
  done
}

apply_candidate() {
  local host="$1" candidate="$2" mode="$3"
  check_host "$host"
  check_kernel "$candidate"
  case "$mode" in
    test) "$candidate/bin/switch-to-configuration" test ;;
    persist)
      if [[ "$host" == hadal-abyss-zone ]]; then
        [[ "${candidate##*/}" =~ ^[a-z0-9]{32}-nixos-system-hadal-abyss-zone-[0-9] &&
           -e "$candidate/etc/systemd/system/multi-user.target.wants/hadal-vm-storage.service" ]] ||
          die 'Hadal persistence requires the normal profile with automatic storage activation'
      fi
      check_running "$candidate"
      check_services "$host" "$candidate" quiet
      /run/current-system/sw/bin/nix-env --profile /nix/var/nix/profiles/system --set "$candidate"
      "$candidate/bin/switch-to-configuration" boot
      ;;
    *) die "Unknown deployment mode: $mode" ;;
  esac
}

host="$1"
candidate="$2"
action="$3"
shift 3
check_host "$host"

case "$action" in
  identify)
    sudo -n true
    test -x /run/current-system/sw/bin/flock
    ;;
  preview)
    mode="$1"
    profile="$2"
    check_kernel "$candidate"
    previous="$(readlink -e /run/current-system)"
    printf '\nCurrent runtime: %s\nManual runtime rollback (not a data restore):\n  sudo %s/bin/switch-to-configuration test\n' \
      "$previous" "$previous"
    if [[ "$profile" == normal ]]; then
      previous_profile="$(readlink -e /nix/var/nix/profiles/system)"
      printf 'Current system profile: %s\nManual profile and boot restore if persistence fails:\n' "$previous_profile"
      printf '  sudo nix-env --profile /nix/var/nix/profiles/system --set %s\n  sudo %s/bin/switch-to-configuration boot\n' \
        "$previous_profile" "$previous_profile"
    fi
    if [[ "$mode" == persist ]]; then check_running "$candidate"; fi
    sudo -n "$candidate/bin/switch-to-configuration" dry-activate
    if [[ "$host" == hadal-abyss-zone ]]; then
      sudo -n systemctl show microvm@rke2.service microvm@openbao.service microvm@postgresql.service \
        -p Id -p ActiveState -p SubState -p Result -p TimeoutStartUSec
    fi
    ;;
  launch)
    unit="$1"
    mode="$2"
    timeout="$3"
    lock_file="$4"
    # The transient unit owns the lock and rechecks the kernel and runtime.
    # Its PATH and shell arguments must survive the systemd manager boundary.
    payload="$(declare -f die check_host check_kernel check_running check_services apply_candidate)"
    payload+=$'\napply_candidate "$@"'
    sudo -n systemd-run --unit="$unit" --no-block \
      --expand-environment=no --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin \
      --property=Type=oneshot --property=RemainAfterExit=yes --property=TimeoutStartSec="$timeout" \
      /run/current-system/sw/bin/flock --nonblock "$lock_file" \
      /run/current-system/sw/bin/bash -euo pipefail -c "$payload" -- "$host" "$candidate" "$mode"
    ;;
  verify)
    unit="$1"
    mode="$2"
    profile="$3"
    check_running "$candidate"
    if [[ "$mode" == persist ]]; then
      [[ "$(readlink -e /nix/var/nix/profiles/system)" == "$candidate" ]] ||
        die 'System profile does not match the candidate. Inspect persistence before rebooting.'
    fi
    sudo -n journalctl -u "$unit.service" -n 50 --no-pager
    if [[ "$profile" == normal ]]; then
      check_services "$host" "$candidate" show
    else
      sudo -n systemctl show microvm@rke2.service microvm@openbao.service microvm@postgresql.service \
        -p Id -p ActiveState -p SubState -p Result
    fi
    printf '\nFailed units (including any pre-existing failures):\n'
    systemctl --failed --no-pager
    ;;
  *) die "Unknown deployment action: $action" ;;
esac
REMOTE
)"

run_remote() {
  # The hostname, canonical candidate path, and action arguments are constrained
  # before passing them to SSH, which joins the arguments into a shell command.
  ssh "${ssh_options[@]}" "$target" bash -s -- "$host" "$candidate" "$@" <<< "$remote_script"
}

candidate_command() {
  local -a options=("$1")
  if [[ "$profile" == storage-provisioning ]]; then options+=(--provisioning); fi
  printf '  %q %q --candidate %q --target %q --identity %q' \
    "$repo_dir/scripts/deploy.sh" "$host" "$candidate" "$target" "$identity"
  printf ' %q' "${options[@]}"
  printf '\n'
}

printf 'Candidate: %s\nTarget: %s\n' "$candidate" "$target"
run_remote identify

copy_target="$target"
if [[ "${target#*@}" == *:* ]]; then copy_target="${target%@*}@[${target#*@}]"; fi
# Float Play trusts workspace for unsigned local closures over ssh-ng.
nix copy "${copy_options[@]}" --to "$copy_transport://$copy_target" "$candidate"

run_remote preview "$mode" "$profile"
case "$mode" in
  preview)
    printf '\nPreview only. To test-activate this exact candidate:\n'
    candidate_command --activate
    exit 0
    ;;
  test)
    printf '\nReview the unit restarts above. Network access and services can be interrupted.\n'
    if [[ "$host" == hadal-abyss-zone ]]; then printf 'OpenBao may require manual unsealing.\n'; fi
    read -r -p 'Type DEPLOY to test-activate this candidate: ' confirmation || die 'No confirmation received'
    [[ "$confirmation" == DEPLOY ]] || die 'Activation cancelled'
    ;;
  persist)
    printf '\nThis updates the system profile and boot entries for the tested runtime.\n'
    read -r -p 'Type PERSIST to make this candidate the boot default: ' confirmation || die 'No confirmation received'
    [[ "$confirmation" == PERSIST ]] || die 'Persistence cancelled'
    ;;
esac

unit="$unit_prefix-$mode-$(date -u +%Y%m%dT%H%M%SZ)-$$"
printf 'Deployment unit: %s.service\n' "$unit"
if ! run_remote launch "$unit" "$mode" "$activation_timeout" "/run/lock/$unit_prefix.lock"; then
  printf 'SSH did not acknowledge deployment; checking the named unit before assuming failure.\n' >&2
fi

deadline=$((SECONDS + monitoring_timeout))
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
      ((missing += 1))
      ((missing < 6)) || die "Deployment unit not found. Inspect $host before retrying: $unit.service"
    else
      missing=0
      if [[ "$status" == *ActiveState=failed* ]]; then
        ssh "${ssh_options[@]}" "$target" sudo -n journalctl -u "$unit.service" -n 80 --no-pager || true
        die "Deployment failed. Inspect $unit.service and the printed restore commands."
      fi
      if [[ "$status" == *ActiveState=active* && "$status" == *SubState=exited* && "$status" == *Result=success* ]]; then
        break
      fi
    fi
  else
    printf 'Waiting for SSH to return; inspect %s.service on %s if the connection stays down.\n' "$unit" "$host"
  fi
  sleep 5
done
((SECONDS < deadline)) || die "Monitoring timed out. Inspect $unit.service before retrying."

run_remote verify "$unit" "$mode" "$profile"
if [[ "$mode" == persist ]]; then
  printf '\nTested runtime persisted to the system profile and boot configuration.\n'
else
  printf '\nRuntime activation completed. Review the reported services and application health.\n'
  if [[ "$profile" == normal ]]; then
    printf 'To persist this exact candidate after validation:\n'
    candidate_command --persist
  fi
fi
