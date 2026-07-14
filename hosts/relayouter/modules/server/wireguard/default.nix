{ config, ... }:

let
  tunnelIp4 = "10.99.0.1";
  tunnelIp6 = "fd99:0::1";
  peerIp4 = "10.99.0.2";
  peerIp6 = "fd99:0::2";
  serverLan6 = "fd10:10:0::/64";
  listenPort = 51820;
in {
  age.secrets.wg0-key = {
    file = ../../../../../secrets/wg0-relayouter.age;
    mode = "0400";
    owner = "root";
    group = "systemd-network";
  };

  networking.wireguard.interfaces.wg0 = {
    ips = [ "${tunnelIp4}/24" "${tunnelIp6}/64" ];
    listenPort = listenPort;
    privateKeyFile = config.age.secrets.wg0-key.path;

    peers = [{
      # hadal-abyss-zone
      publicKey = "REPLACE_WITH_HADAL_ABYSS_ZONE_PUBLIC_KEY";
      # The far side reaches us over the tunnel from its LAN clients too,
      # so accept traffic sourced from the server LAN v6 range.
      allowedIPs = [
        "${peerIp4}/32"
        "${peerIp6}/128"
        serverLan6
      ];
      persistentKeepalive = 25;
    }];
  };

  networking.firewall.allowedUDPPorts = [ listenPort ];
}
