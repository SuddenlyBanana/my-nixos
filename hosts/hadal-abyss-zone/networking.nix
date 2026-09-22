{ secrets, ... }:

{
  systemd.network = {
    netdevs."10-br-lan" = {
      netdevConfig = {
        Kind = "bridge";
        Name = "br-lan";
        MTUBytes = "9000";
      };
    };

    netdevs."20-br-mgmt" = {
      netdevConfig = {
        Kind = "bridge";
        Name = "br-mgmt";
      };
    };

    networks."10-br-lan" = {
      matchConfig.Name = "br-lan";
      address = [ "${secrets.privateIps.hadal-abyss-zone.static.v6}/64" ];
      routes = [{
        Gateway = secrets.privateIps.yurail.v6;
      }];
      networkConfig = {
        DHCP = "ipv6";
        IPv6AcceptRA = true;
      };
      dhcpV6Config = {
        PrefixDelegationHint = "::/64";
        UseAddress = false;
        WithoutRA = "solicit";
      };
      linkConfig.MTUBytes = "9000";
    };

    networks."15-usb-tether" = {
      matchConfig.Name = "enp0s20f0u1";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
    };

    networks."20-br-mgmt" = {
      matchConfig.Name = "br-mgmt";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
	    MulticastDNS = true;
      };
    };

    networks."21-eno1" = {
      matchConfig.Name = "eno1";
      networkConfig = {
        Bridge = "br-mgmt";
        LinkLocalAddressing = "no";
      };
    };
  };

  networking.nftables.enable = true;

  # System resolver → local unbound. v6-only per the internal design.
  networking.nameservers = [ "::1" ];

  networking.firewall = {
    filterForward = true;

    extraForwardRules = ''
      iifname { "br-lan", "br-web", "wg0" } \
        oifname { "br-lan", "br-web", "wg0" } \
        accept comment "internal routed networks"
    '';

    interfaces.br-mgmt = {
      allowedTCPPorts = [ 22 ];
      allowedUDPPorts = [ 5353 ];
    };
  };

  # NixOS as fallback gateway
  networking.nat = {
    enable = true;
    externalInterface = "enp0s20f0u1";
    internalInterfaces = [ "br-lan" ];
  };
}
