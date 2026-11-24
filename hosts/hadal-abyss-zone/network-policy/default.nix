{
  config,
  lib,
  secrets,
  ...
}:

let
  topology = import ../modules/virt/microvms/topology.nix { inherit secrets; };
  nat64 = import ../../../modules/server/nat64-topology.nix { inherit secrets; };
  zones = import ./zones.nix { inherit secrets; };
  protected = "{ ${zones.internal.prefix}, ${zones.remoteAccess.prefix} }";
  nat64Clients = lib.concatStringsSep ", " nat64.clientPrefixes;
  clusterClients = "{ ${topology.service.rke2Address}/128, ${topology.cluster.podCidr} }";
  mail = import ../../../modules/server/mail-topology.nix { inherit secrets; };
  ingressPorts = lib.concatMapStringsSep ", " toString ([ topology.cluster.ingressHttpNodePort ] ++ mail.nodePorts);
in
{
  assertions = [
    {
      assertion = !(config.hadal.backups.enable or false);
      message = "Hadal's DMZ policy forbids the legacy NAS-push backup backend. Keep hadal.backups.enable=false; implement internal-initiated pull backups instead.";
    }
  ];

  # These are return paths, not permission for Hadal to initiate connections.
  # Pin the stable host source independently of SLAAC/privacy addresses.
  systemd.network.networks."10-br-lan".routes =
    map
      (prefix: {
        Destination = prefix;
        Gateway = secrets.privateIps.yurail.v6;
        PreferredSource = secrets.privateIps.hadal-abyss-zone.static.v6;
      })
      [
        zones.internal.prefix
        zones.remoteAccess.prefix
      ];

  networking.nftables.tables.hadal-zone-boundary = {
    family = "inet";
    content = ''
      chain protected-destination {
        ct state { established, related } return
        # Permit IPv6 errors/PMTU feedback, not new ping or application flows.
        icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } return
        counter drop comment "DMZ cannot initiate into internal or VPN zones"
      }

      chain forward {
        type filter hook forward priority filter - 5; policy accept;
        ip6 daddr ${protected} jump protected-destination
      }

      chain output {
        type filter hook output priority filter - 5; policy accept;
        ip6 daddr ${protected} jump protected-destination
      }
    '';
  };

  networking.firewall = {
    filterForward = true;

    extraInputRules = ''
      # Transport only: backup identity/forced command and pull jobs are separate.
      iifname "br-lan" ip6 saddr ${zones.internal.backupHost}/128 \
        ip6 daddr ${secrets.privateIps.hadal-abyss-zone.static.v6}/128 \
        tcp dport 22 accept comment "ipace initiates backup transport to Hadal"

      iifname "wg0" ip6 saddr ${secrets.privateIps.float-play.v6}/128 \
        tcp dport { 22, 53 } accept comment "float-play host management and DNS"
      iifname "wg0" ip6 saddr ${secrets.privateIps.float-play.v6}/128 \
        udp dport 53 accept comment "float-play DNS"
    '';

    extraForwardRules = ''
      # All decrypted float-play ingress is pinned to its address and NodePort.
      iifname "wg0" oifname "br-web" \
        ip6 saddr ${secrets.privateIps.float-play.v6}/128 \
        ip6 daddr ${topology.service.rke2Address}/128 \
        tcp dport { ${ingressPorts} } \
        accept comment "float-play to RKE2 ingress"

      iifname "br-web" oifname "wg0" \
        ip6 saddr ${topology.service.rke2Address}/128 ip6 daddr ${mail.relayAddress}/128 \
        tcp dport ${toString mail.relayPort} accept comment "RKE2 to float-play SMTP relay"

      iifname { "br-lan", "br-web" } oifname "wg0" \
        ip6 saddr { ${nat64Clients} } ip6 daddr ${nat64.prefix} \
        accept comment "scoped NAT64 egress through float-play"

      # Node/pod traffic may use delegated global source addresses. Do not pin
      # this to a static source /64 or native-IPv6 image downloads will break.
      iifname "br-web" oifname "br-lan" ip6 daddr 2000::/3 \
        accept comment "RKE2 native IPv6 Internet egress"

      # Preserve the existing LAN PostgreSQL permission, now source-scoped.
      # The new internal/VPN prefixes do not gain direct database access.
      iifname "br-lan" oifname "br-db" \
        ip6 saddr ${secrets.privateIps.subnets.homelabLan} \
        ip6 daddr ${topology.infrastructure.postgresqlAddress}/128 \
        tcp dport 5432 accept comment "existing LAN PostgreSQL clients"

      iifname "br-web" oifname "br-db" \
        ip6 saddr ${clusterClients} \
        ip6 daddr ${topology.infrastructure.postgresqlAddress}/128 \
        tcp dport 5432 accept comment "RKE2 workloads to PostgreSQL"

      iifname "br-web" oifname "br-db" \
        ip6 saddr ${clusterClients} \
        ip6 daddr ${topology.infrastructure.openbaoAddress}/128 \
        tcp dport 8200 accept comment "RKE2 workloads to OpenBao"

      iifname "br-db" oifname "br-web" \
        ip6 saddr ${topology.infrastructure.openbaoAddress}/128 \
        ip6 daddr ${topology.service.rke2Address}/128 \
        tcp dport 6443 accept comment "OpenBao Kubernetes authentication"
    '';
  };
}
