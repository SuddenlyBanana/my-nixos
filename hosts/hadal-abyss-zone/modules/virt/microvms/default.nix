{ secrets, ... }:

let
  servicePrefix = secrets.privateIps.hadal-abyss-zone.subnets.serviceLan;
  hostAddress = "${secrets.privateIps.prefixes.homelabUla}:9::1";
in
{
  imports = [ ./wapmail.nix ];

  systemd.network = {
    netdevs."30-br-web".netdevConfig = {
      Kind = "bridge";
      Name = "br-web";
      MTUBytes = "9000";
    };

    networks."30-br-web" = {
      matchConfig.Name = "br-web";
      address = [ "${hostAddress}/64" ];
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
        DNS = hostAddress;
        UplinkInterface = "br-lan";
      };
      ipv6Prefixes = [{
        Prefix = servicePrefix;
        AddressAutoconfiguration = true;
        OnLink = true;
      }];
      linkConfig.MTUBytes = "9000";
    };

    networks."31-web-guests" = {
      matchConfig.Name = "vm-web-*";
      networkConfig.Bridge = "br-web";
      linkConfig.MTUBytes = "9000";
    };
  };

  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

  # Guests use the host's recursive resolver over the dedicated bridge.
  services.unbound.settings.server = {
    interface = [ hostAddress ];
    access-control = [ "${servicePrefix} allow" ];
  };
  networking.firewall.interfaces.br-web = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
}
