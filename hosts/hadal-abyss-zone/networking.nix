{ secrets, ... }:

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

    # Out-of-band management bridge.  Keep eno1 as an L2-only bridge port so
    # libvirt guests and Podman macvlan networks can attach to br-mgmt and get
    # addresses directly from the management network.
    netdevs."20-br-mgmt" = {
      netdevConfig = {
        Kind = "bridge";
        Name = "br-mgmt";
      };
    };

    networks."10-br-lan" = {
      matchConfig.Name = "br-lan";
      address = [ secrets.privateIps.hadal-abyss-zone.v6 ];
      routes = [{
        Gateway = secrets.privateIps.yurail.v6;
        Metric = 500;
      }];
      networkConfig.IPv6AcceptRA = true;
    };

    networks."15-usb-tether" = {
      matchConfig.Name = "enp0s20f0u1";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      dhcpV4Config = {
        RouteMetric = 50;
        UseDNS = false;
      };
    };

    # The host is a peer on the management network, rather than eno1 itself.
    networks."20-br-mgmt" = {
      matchConfig.Name = "br-mgmt";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
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

  # System resolver → local unbound. v6-only per the internal design.
  networking.nameservers = [ "::1" ];
  networking.firewall.trustedInterfaces = [ "br-lan" ];

  # nixos as fallback gateway
  networking.nat = {
    enable = true;
    externalInterface = "enp0s20f0u1";
    internalInterfaces = [ "br-lan" ];
  };

}
