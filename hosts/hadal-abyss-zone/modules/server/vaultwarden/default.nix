{ lib, pkgs, secrets, ... }:

let
  dataDir = "/srv/media/vaultwarden";
  port = 8222;
in
{
  # Used to generate the Argon2id PHC hash stored in admin.env.
  environment.systemPackages = [ pkgs.libargon2 ];

  services.vaultwarden = {
    enable = true;
    dbBackend = "sqlite";
    config = {
      DOMAIN = "https://vault.${secrets.zones.float-play.domain1.name}";
      DATA_FOLDER = dataDir;
      DATABASE_URL = "sqlite://${dataDir}/db.sqlite3";
      SIGNUPS_ALLOWED = false;
      INVITATIONS_ALLOWED = true;
      ENABLE_WEBSOCKET = true;
      ROCKET_ADDRESS = secrets.privateIps.hadal-abyss-zone.wg-tunnel.v6;
      ROCKET_PORT = port;
    };
  };

  systemd.services.vaultwarden = {
    unitConfig = {
      RequiresMountsFor = "/srv/media";
      AssertPathIsMountPoint = "/srv/media";
    };
    serviceConfig = {
      ReadWritePaths = [ dataDir ];
      ExecStartPre = "+${pkgs.coreutils}/bin/install -d -m 0700 -o vaultwarden -g vaultwarden ${dataDir}";
      EnvironmentFile = lib.mkAfter [ "-${dataDir}/admin.env" ];
    };
  };

  systemd.tmpfiles.rules = [ "d ${dataDir} 0700 vaultwarden vaultwarden -" ];

  networking.firewall.interfaces.wg0.allowedTCPPorts = [ port ];
}
