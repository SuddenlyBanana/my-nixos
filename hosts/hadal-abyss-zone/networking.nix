{ config, secrets, ... }:

let
  topology = import ./modules/virt/microvms/topology.nix { inherit secrets; };
  nat64 = import ../../modules/server/nat64-topology.nix { inherit secrets; };
in
{
  systemd.network = {
    netdevs = {
      "10-br-lan" = {
        netdevConfig = {
          Kind = "bridge";
          Name = "br-lan";
          MTUBytes = "9000";
        };
      };

      "20-br-mgmt" = {
        netdevConfig = {
          Kind = "bridge";
          Name = "br-mgmt";
        };
      };
    };

    networks = {
      "10-br-lan" = {
        matchConfig.Name = "br-lan";
        address = [ "${secrets.privateIps.hadal-abyss-zone.static.v6}/64" ];
        routes = [
          {
            Gateway = secrets.privateIps.yurail.v6;
          }
        ];
        networkConfig = {
          DHCP = "ipv6";
          IPv6AcceptRA = true;
        };
        dhcpV6Config = {
           DUIDType = "link-layer";
           PrefixDelegationHint = "::/64";
           UseAddress = false;
           WithoutRA = "solicit";
        };
        # Keep the local jumbo MTU even if the uplink advertises a smaller one.
        # Smaller routed paths must return ICMPv6 Packet Too Big messages.
        ipv6AcceptRAConfig.UseMTU = false;
        linkConfig.MTUBytes = "9000";
      };

      "20-br-mgmt" = {
        matchConfig.Name = "br-mgmt";
        networkConfig = {
          DHCP = "yes";
          IPv6AcceptRA = true;
          MulticastDNS = true;
        };
      };

      "21-eno1" = {
        matchConfig.Name = "eno1";
        networkConfig = {
          Bridge = "br-mgmt";
          LinkLocalAddressing = "no";
        };
      };
    };
  };

  networking = {
    nameservers = [ "::1" ];

    wireguard.interfaces.wg0 = {
      ips = [ "${secrets.privateIps.hadal-abyss-zone.wg-tunnel.v6}/64" ];
      privateKeyFile = config.age.secrets.wg0-key.path;

      peers = [
        {
          # float-play
          publicKey = "KFN3g9/+S1y12ET0kgUh2+DfAiEha3x/jg4yE5k2FQ0=";
          endpoint = "${secrets.publicIps.float-play.v6}:51820";
          allowedIPs = [
            "${secrets.privateIps.float-play.v6}/128"
            nat64.prefix
          ];
          persistentKeepalive = 25;
        }
      ];
    };

    nftables.enable = true;
    firewall = {
      filterForward = true;

      # In-band host management: allow only homelab LAN clients to the stable
      # LAN address, not service/pod networks or SLAAC/global host addresses.
      # Keep br-mgmt and WireGuard access below as independent fallback paths.
      extraInputRules = ''
        iifname "br-lan" \
          ip6 saddr ${secrets.privateIps.subnets.homelabLan} \
          ip6 daddr ${secrets.privateIps.hadal-abyss-zone.static.v6} \
          tcp dport 22 \
          accept comment "in-band hadal SSH from homelab LAN"
      '';

      extraForwardRules = ''
        iifname { "br-lan", "br-web", "wg0" } \
          oifname { "br-lan", "br-web", "wg0" } \
          accept comment "internal routed networks"

        iifname "br-lan" oifname "br-db" \
          ip6 daddr ${topology.infrastructure.postgresqlAddress} \
          tcp dport 5432 \
          accept comment "homelab clients to PostgreSQL"

        iifname "br-web" oifname "br-db" \
          ip6 daddr ${topology.infrastructure.postgresqlAddress} \
          tcp dport 5432 \
          accept comment "RKE2 workloads to PostgreSQL"

        iifname "br-web" oifname "br-db" \
          ip6 daddr ${topology.infrastructure.openbaoAddress} \
          tcp dport 8200 \
          accept comment "RKE2 workloads to OpenBao"

        iifname "br-db" oifname "br-web" \
          ip6 saddr ${topology.infrastructure.openbaoAddress} \
          ip6 daddr ${topology.service.rke2Address} \
          tcp dport 6443 \
          accept comment "OpenBao Kubernetes authentication to API server"
      '';

      interfaces = {
        br-mgmt = {
          allowedTCPPorts = [ 22 ];
          allowedUDPPorts = [ 5353 ];
        };
        wg0.allowedTCPPorts = [
          22
          53
        ];
      };
    };
  };

  age.secrets.wg0-key = {
    file = secrets.paths.wg0-hadal-abyss-zone;
    mode = "0400";
    owner = "root";
    group = "systemd-network";
  };
}
