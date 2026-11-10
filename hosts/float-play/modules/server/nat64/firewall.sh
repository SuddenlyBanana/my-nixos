#!/usr/bin/env bash
set -euo pipefail
export XTABLES_LIBDIR='@XTABLES_LIBDIR@'

remove_rules() {
  ip6tables -w -t mangle -D PREROUTING -i wg0 -d '@PREFIX@' -j HADAL-NAT64-V6 2>/dev/null || true
  iptables -w -t mangle -D PREROUTING -d '@PUBLIC_IPV4@/32' -j HADAL-NAT64-V4 2>/dev/null || true
  for command in ip6tables iptables; do
    if [[ "$command" == ip6tables ]]; then chain=HADAL-NAT64-V6; else chain=HADAL-NAT64-V4; fi
    "$command" -w -t mangle -F "$chain" 2>/dev/null || true
    "$command" -w -t mangle -X "$chain" 2>/dev/null || true
  done
}

case "${1:-}" in
  stop) remove_rules; exit 0 ;;
  start) remove_rules ;;
  *) echo 'usage: firewall.sh start|stop' >&2; exit 2 ;;
esac

ip6tables -w -t mangle -N HADAL-NAT64-V6
iptables -w -t mangle -N HADAL-NAT64-V4

# Do not allow DNS64 to turn private IPv4 services into public-looking IPv6
# destinations (notably for user-selected WAPmail servers).
for destination in \
  64:ff9b::/104 64:ff9b::a00:0/104 64:ff9b::6440:0/106 \
  64:ff9b::7f00:0/104 64:ff9b::a9fe:0/112 64:ff9b::ac10:0/108 \
  64:ff9b::c0a8:0/112 64:ff9b::c612:0/111 64:ff9b::e000:0/100 \
  64:ff9b::f000:0/100; do
  ip6tables -w -t mangle -A HADAL-NAT64-V6 -d "$destination" -j DROP
done
# The Nix template expands this token into a space-separated list of CIDRs.
# shellcheck disable=SC2043
for source in @IPV6_SOURCES@; do
  ip6tables -w -t mangle -A HADAL-NAT64-V6 -s "$source" -j JOOL --instance hadal
done
ip6tables -w -t mangle -A HADAL-NAT64-V6 -j DROP

# No static BIB/port-forward entries. Return packets must match Jool state.
for protocol in tcp udp; do
  iptables -w -t mangle -A HADAL-NAT64-V4 -p "$protocol" --dport 61001:65535 -j JOOL --instance hadal
done
iptables -w -t mangle -A HADAL-NAT64-V4 -p icmp -j JOOL --instance hadal
ip6tables -w -t mangle -A PREROUTING -i wg0 -d '@PREFIX@' -j HADAL-NAT64-V6
iptables -w -t mangle -A PREROUTING -d '@PUBLIC_IPV4@/32' -j HADAL-NAT64-V4
