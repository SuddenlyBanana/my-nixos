{ config, secrets, ... }:

let
  listenPort = 51820;
in {
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  age.secrets.wg0-key = {
    file = secrets.paths.wg0-float-play;
    mode = "0400";
    owner = "root";
    group = "systemd-network";
  };

  networking.wireguard.interfaces.wg0 = {
    ips = [ "${secrets.privateIps.float-play.v6}/64" ];
    listenPort = listenPort;
    privateKeyFile = config.age.secrets.wg0-key.path;

    peers = [{
      # hadal-abyss-zone
      publicKey = "x2sjpAl30O+WoxtruQ+T6X4XA7T/m/KJ3pY2vcRGUAY=";
      allowedIPs = [ "${secrets.privateIps.hadal-abyss-zone.wg-tunnel.v6}/128" secrets.privateIps.prefixes.homelabUla ];
      persistentKeepalive = 25;
    }];
  };

  networking.firewall.allowedUDPPorts = [ listenPort ];
}
