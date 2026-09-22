{ pkgs, secrets, ... }:

let
  serviceAddress = "${secrets.privateIps.prefixes.homelabUla}:9::11";
  serviceHostAddress = "${secrets.privateIps.prefixes.homelabUla}:9::1";
  databaseAddress = "${secrets.privateIps.prefixes.homelabUla}:209::11";
  databaseHostAddress = "${secrets.privateIps.prefixes.homelabUla}:209::1";
  floatPlayAddress = secrets.privateIps.float-play.v6;
  dataImage = "/srv/media/services/vaultwarden/data.raw";
  credentialImage = "/srv/media/services/vaultwarden/credentials.raw";
  postgresCaImage = "/srv/media/services/postgresql/ca.raw";
  serviceMacAddress = "02:00:00:00:01:11";
  databaseMacAddress = "02:00:00:02:09:11";
  port = 8222;
in
{
  # Keep the admin-token generation utility available on the host.
  environment.systemPackages = [
    pkgs.libargon2
    pkgs.rsync
    pkgs.sqlite
  ];

  microvm.vms.vaultwarden.config = { lib, ... }: {
    imports = [
      (import ./snapshot-agent.nix {
        controlAddress = databaseAddress;
        mountPoint = "/var/lib/vaultwarden";
        quiesceUnits = [ "vaultwarden.service" ];
      })
    ];

    networking.hostName = "vaultwarden";
    system.stateVersion = "26.05";

    microvm = {
      hypervisor = "firecracker";
      mem = 768;
      vcpu = 1;
      storeOnDisk = true;
      interfaces = [
        {
          type = "tap";
          id = "vm-web-02";
          mac = serviceMacAddress;
        }
        {
          type = "tap";
          id = "vm-db-02";
          mac = databaseMacAddress;
        }
      ];
      volumes = [
        {
          image = dataImage;
          mountPoint = "/var/lib/vaultwarden";
          label = "vaultwarden-data";
          size = 16384;
          fsType = "ext4";
        }
        {
          image = credentialImage;
          mountPoint = "/run/vaultwarden-credentials";
          size = 8;
          fsType = "ext4";
          autoCreate = false;
          readOnly = true;
        }
        {
          image = postgresCaImage;
          mountPoint = "/etc/postgresql-ca";
          size = 8;
          fsType = "ext4";
          autoCreate = false;
          readOnly = true;
        }
      ];
    };

    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.nameservers = [ serviceHostAddress ];
    systemd.network.networks = {
      "20-service" = {
        matchConfig.MACAddress = serviceMacAddress;
        linkConfig.MTUBytes = "1280";
        address = [ "${serviceAddress}/64" ];
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = true;
        };
        ipv6AcceptRAConfig.UseMTU = false;
      };
      "21-database" = {
        matchConfig.MACAddress = databaseMacAddress;
        linkConfig.MTUBytes = "9000";
        address = [ "${databaseAddress}/64" ];
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
        };
      };
    };

    services.vaultwarden = {
      enable = true;
      dbBackend = "postgresql";
      environmentFile = "/run/vaultwarden-credentials/vaultwarden.env";
      config = {
        DOMAIN = "https://vault.${secrets.zones.float-play.domain1.name}";
        DATA_FOLDER = "/var/lib/vaultwarden";
        SIGNUPS_ALLOWED = false;
        INVITATIONS_ALLOWED = true;
        ENABLE_WEBSOCKET = true;
        DB_CONNECTION_RETRIES = 30;
        ROCKET_ADDRESS = serviceAddress;
        ROCKET_PORT = port;
      };
    };

    systemd.services.vaultwarden = {
      unitConfig.RequiresMountsFor = [
        "/var/lib/vaultwarden"
        "/run/vaultwarden-credentials"
        "/etc/postgresql-ca"
      ];
      serviceConfig = {
        ReadWritePaths = [ "/var/lib/vaultwarden" ];
        EnvironmentFile = lib.mkAfter [ "-/var/lib/vaultwarden/admin.env" ];
      };
    };

    networking.nftables.enable = true;
    networking.firewall = {
      enable = true;
      extraInputRules = ''
        ip6 saddr { ${floatPlayAddress}/128, ${serviceHostAddress}/128 } \
          tcp dport ${toString port} accept
        ip6 saddr ${databaseHostAddress}/128 tcp dport 9100 accept
      '';
    };

    services.journald.extraConfig = ''
      ForwardToConsole=yes
      TTYPath=/dev/console
      MaxLevelConsole=notice
    '';
  };
}
