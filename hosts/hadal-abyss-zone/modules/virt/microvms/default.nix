{ secrets, ... }:

let
  # Dedicated ULA subnet for app guests. Allocate one unique address per app.
  webPrefix = "fd8b:9dca:b9ce:1::/64";
  hostAddress = "fd8b:9dca:b9ce:1::1";
  lanPrefix = secrets.privateIps.prefixes.homelabUla;
in
{
  imports = [ ./wapmail.nix ];

  systemd.network = {
    netdevs."30-br-web".netdevConfig = {
      Kind = "bridge";
      Name = "br-web";
    };

    networks."30-br-web" = {
      matchConfig.Name = "br-web";
      address = [ "${hostAddress}/64" ];
      networkConfig.IPv6AcceptRA = false;
    };

    networks."31-web-guests" = {
      matchConfig.Name = "vm-web-*";
      networkConfig.Bridge = "br-web";
    };
  };

  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;

  # Guests use the host's recursive resolver over the dedicated bridge.
  services.unbound.settings.server = {
    interface = [ hostAddress ];
    access-control = [ "${webPrefix} allow" ];
  };
  networking.firewall.interfaces.br-web = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };

  # The LAN router does not have a return route for the guest prefix. Use
  # hadal's LAN ULA for LAN traffic and a usable address on br-lan for public
  # IPv6 destinations.
  networking.firewall.extraCommands = ''
    ip6tables -t nat -D POSTROUTING -s ${webPrefix} -o br-lan -j SNAT --to-source ${secrets.privateIps.hadal-abyss-zone.static.v6} || true
    ip6tables -t nat -A POSTROUTING -s ${webPrefix} -d ${lanPrefix} -o br-lan -j SNAT --to-source ${secrets.privateIps.hadal-abyss-zone.static.v6}
    ip6tables -t nat -A POSTROUTING -s ${webPrefix} -o br-lan -j MASQUERADE
  '';
  networking.firewall.extraStopCommands = ''
    ip6tables -t nat -D POSTROUTING -s ${webPrefix} -d ${lanPrefix} -o br-lan -j SNAT --to-source ${secrets.privateIps.hadal-abyss-zone.static.v6} || true
    ip6tables -t nat -D POSTROUTING -s ${webPrefix} -o br-lan -j MASQUERADE || true
  '';
}
