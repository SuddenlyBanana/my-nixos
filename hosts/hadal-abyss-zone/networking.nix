{ ... }:

{
  # Host <-> OpnSense LAN bridge. Both physical NICs are PCI-passthrough'd
  # to OpnSense (see hosts/hadal-abyss-zone/vms/opnsense.nix), so hadal has no
  # direct WAN — OpnSense attaches a virtio-net into br-lan and routes for us.
  # Static v4 + ULA v6 keep the host reachable and serving DNS independent of
  # OpnSense DHCP/RA being up. A routable GUA is picked up from OpnSense's RAs
  # on top of the static ULA when the ISP hands out a prefix.
  systemd.network = {
    netdevs."10-br-lan" = {
      netdevConfig = {
        Kind = "bridge";
        Name = "br-lan";
      };
    };

    networks."10-br-lan" = {
      matchConfig.Name = "br-lan";
      address = [ "10.10.0.2/24" "fd10:10:0::2/64" ];
      routes = [
        {
          Gateway = "10.10.0.1";
          Metric = 500;
        }
        {
          Gateway = "fd10:10:0::1";
          Metric = 500;
        }
      ];
      networkConfig.IPv6AcceptRA = true;
    };

    networks."15-usb-tether" = {
      matchConfig.Name = "enp0s20f0u2";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      dhcpV4Config = {
        RouteMetric = 50;
        UseDNS = false;
      };
    };

    # Out-of-band management NIC — DHCP from whatever's on that segment.
    networks."20-eno1" = {
      matchConfig.Name = "eno1";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
    };
  };

  # System resolver → local unbound. v6-only per the internal design.
  networking.nameservers = [ "::1" ];
  networking.firewall.trustedInterfaces = [ "br-lan" ];

  # nixos as fallback gateway
  networking.nat = {
    enable = true;
    externalInterface = "enp0s20f0u2";
    internalInterfaces = [ "br-lan" ];
  };

  # mDNS on the out-of-band management NIC so hadal-abyss-zone.local
  # resolves from the workstation even when the LAN side is down.
  services.avahi = {
    enable = true;
    allowInterfaces = [ "eno1" ];
    publish = {
      enable = true;
      addresses = true;
      domain = true;
    };
    openFirewall = true;
  };
}
