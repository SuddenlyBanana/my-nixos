{ config, ... }:

let
  tunnelIp4 = "10.99.0.2";
  tunnelIp6 = "fd99:0::2";
  peerIp4 = "10.99.0.1";
  peerIp6 = "fd99:0::1";
  nat64Prefix = "64:ff9b::/96";

  # relayouter's public IPv4 + WireGuard listen port.
  relayouterEndpoint = "64.176.71.121:51820";
in {
  age.secrets.wg0-key = {
    file = ../../../../../secrets/wg0-hadal-abyss-zone.age;
    mode = "0400";
    owner = "root";
    group = "systemd-network";
  };

  networking.wireguard.interfaces.wg0 = {
    ips = [ "${tunnelIp4}/24" "${tunnelIp6}/64" ];
    privateKeyFile = config.age.secrets.wg0-key.path;

    peers = [{
      publicKey = "KFN3g9/+S1y12ET0kgUh2+DfAiEha3x/jg4yE5k2FQ0=";
      endpoint = relayouterEndpoint;
      # Tunnel endpoints + NAT64 prefix (so v6-only server-LAN clients
      # reach legacy v4 internet via Jool on relayouter).
      allowedIPs = [ "${peerIp4}/32" "${peerIp6}/128" nat64Prefix ];
      persistentKeepalive = 25;
    }];
  };
}
