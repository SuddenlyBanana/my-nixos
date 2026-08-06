{ config, secrets, ... }:

let
  tunnelIp6 = "fd99:0::1";
  peerIp6 = "fd99:0::2";
  serverLan6 = "fd10:10:0::/64";
  listenPort = 51820;
in {
  age.secrets.wg0-key = {
    file = secrets.paths.wg0-relayouter;
    mode = "0400";
    owner = "root";
    group = "systemd-network";
  };

  networking.wireguard.interfaces.wg0 = {
    ips = [ "${tunnelIp6}/64" ];
    listenPort = listenPort;
    privateKeyFile = config.age.secrets.wg0-key.path;

    peers = [{
      # hadal-abyss-zone
      publicKey = "x2sjpAl30O+WoxtruQ+T6X4XA7T/m/KJ3pY2vcRGUAY=";
      # The far side reaches us over the tunnel from its LAN clients too,
      # so accept traffic sourced from the server LAN v6 range.
      allowedIPs = [ "${peerIp6}/128" serverLan6 ];
      persistentKeepalive = 25;
    }];
  };

  networking.firewall.allowedUDPPorts = [ listenPort ];
}
