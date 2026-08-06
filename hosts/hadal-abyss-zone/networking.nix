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
      address = [
        "10.10.0.2/24"
        "fd10:10:0::2/64"
      ];
      routes = [
        { Gateway = "10.10.0.1"; }
        { Gateway = "fd10:10:0::1"; }
      ];
      networkConfig.IPv6AcceptRA = true;
    };
  };

  # System resolver → local unbound. v6-only per the internal design.
  networking.nameservers = [ "::1" ];
  networking.firewall.trustedInterfaces = [ "br-lan" ];
}
