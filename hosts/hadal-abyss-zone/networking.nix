{ config, secrets, ... }:

let
  nat64 = import ../../modules/server/nat64-topology.nix { inherit secrets; };
in
{
  imports = [ ./network-policy ];

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
    # System resolver → local unbound. v6-only per the internal design.
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

      interfaces = {
        br-mgmt = {
          allowedTCPPorts = [ 22 ];
          allowedUDPPorts = [ 5353 ];
        };
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
