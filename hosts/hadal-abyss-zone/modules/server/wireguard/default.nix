{ config, secrets, ... }:

let
  floatPlayEndpoint = "${secrets.publicIps.float-play.v6}:51820";
in {
  age.secrets.wg0-key = {
    file = secrets.paths.wg0-hadal-abyss-zone;
    mode = "0400";
    owner = "root";
    group = "systemd-network";
  };

  networking.wireguard.interfaces.wg0 = {
    ips = [ "${secrets.privateIps.hadal-abyss-zone.wg-tunnel.v6}/64" ];
    privateKeyFile = config.age.secrets.wg0-key.path;

    peers = [{
      # float-play
      publicKey = "KFN3g9/+S1y12ET0kgUh2+DfAiEha3x/jg4yE5k2FQ0=";
      endpoint = floatPlayEndpoint;
      allowedIPs = [ "${secrets.privateIps.float-play.v6}/128" ];
      persistentKeepalive = 25;
    }];
  };
}
