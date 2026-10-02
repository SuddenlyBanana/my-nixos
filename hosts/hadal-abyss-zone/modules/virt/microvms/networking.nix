{ secrets, ... }:

let
  topology = import ./topology.nix { inherit secrets; };
in
{
  systemd.network = {
    netdevs = {
      "30-br-web".netdevConfig = {
        Kind = "bridge";
        Name = "br-web";
        MTUBytes = "9000";
      };

      "40-br-db".netdevConfig = {
        Kind = "bridge";
        Name = "br-db";
        MTUBytes = "9000";
      };
    };

    networks = {
      "30-br-web" = {
        matchConfig.Name = "br-web";
        address = [ "${topology.service.hostAddress}/64" ];
        routes = [
          {
            Destination = topology.cluster.podCidr;
            Gateway = topology.service.rke2Address;
          }
        ];
        networkConfig = {
          DHCPPrefixDelegation = true;
          IPv6AcceptRA = false;
          IPv6SendRA = true;
        };
        dhcpPrefixDelegationConfig = {
          UplinkInterface = "br-lan";
          Announce = true;
          Assign = true;
        };
        ipv6SendRAConfig = {
          Managed = false;
          OtherInformation = false;
          EmitDNS = true;
          DNS = topology.service.hostAddress;
          UplinkInterface = "br-lan";
        };
        ipv6Prefixes = [
          {
            Prefix = topology.service.prefix;
            AddressAutoconfiguration = true;
            OnLink = true;
          }
        ];
        linkConfig.MTUBytes = "9000";
      };

      "31-web-guests" = {
        matchConfig.Name = "vm-web-*";
        networkConfig.Bridge = "br-web";
        linkConfig.MTUBytes = "9000";
      };

      "40-br-db" = {
        matchConfig.Name = "br-db";
        address = [ "${topology.infrastructure.hostAddress}/64" ];
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
        };
        linkConfig.MTUBytes = "9000";
      };

      "41-db-guests" = {
        matchConfig.Name = "vm-db-*";
        networkConfig.Bridge = "br-db";
        linkConfig.MTUBytes = "9000";
      };
    };
  };

  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

  services.unbound.settings.server = {
    interface = [
      topology.service.hostAddress
      topology.infrastructure.hostAddress
    ];
    access-control = [
      "${topology.service.prefix} allow"
      "${topology.infrastructure.prefix} allow"
    ];
  };

  networking.firewall.interfaces = {
    br-web = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    };
    br-db = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    };
  };
}
