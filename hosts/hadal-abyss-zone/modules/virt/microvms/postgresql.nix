{
  lib,
  pkgs,
  secrets,
  ...
}:

let
  hostAddress = "${secrets.privateIps.prefixes.homelabUla}:209::1";
  postgresAddress = "${secrets.privateIps.prefixes.homelabUla}:209::10";
  vaultwardenAddress = "${secrets.privateIps.prefixes.homelabUla}:209::11";
  homelabPrefix = secrets.privateIps.subnets.homelabLan;
  dataImage = "/srv/media/services/postgresql/data.raw";
  credentialImage = "/srv/media/services/vaultwarden/credentials.raw";
  tlsImage = "/srv/media/services/postgresql/tls.raw";
  macAddress = "02:00:00:02:09:10";

  authentication =
    lib.replaceStrings
      [ "@VAULTWARDEN_ADDRESS@" "@HOST_ADDRESS@" "@HOMELAB_PREFIX@" ]
      [ "${vaultwardenAddress}/128" "${hostAddress}/128" homelabPrefix ]
      (builtins.readFile ./postgresql/pg_hba.conf);
in
{
  # Keep migration and emergency client tools available on the host.
  environment.systemPackages = [
    pkgs.pgloader
    pkgs.postgresql_17
  ];

  microvm.vms.postgresql.config =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        (import ./snapshot-agent.nix {
          controlAddress = postgresAddress;
          mountPoint = "/var/lib/postgresql";
        })
      ];

      networking.hostName = "postgresql";
      system.stateVersion = "26.05";

      microvm = {
        hypervisor = "firecracker";
        mem = 2048;
        vcpu = 2;
        storeOnDisk = true;
        interfaces = [
          {
            type = "tap";
            id = "vm-db-01";
            mac = macAddress;
          }
        ];
        volumes = [
          {
            image = dataImage;
            mountPoint = "/var/lib/postgresql";
            label = "postgresql-data";
            size = 65536;
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
            image = tlsImage;
            mountPoint = "/run/postgresql-tls";
            size = 8;
            fsType = "ext4";
            autoCreate = false;
            readOnly = true;
          }
        ];
      };

      networking.useNetworkd = true;
      networking.useDHCP = false;
      networking.nameservers = [ hostAddress ];
      systemd.network.networks."20-database" = {
        matchConfig.MACAddress = macAddress;
        linkConfig.MTUBytes = "9000";
        address = [ "${postgresAddress}/64" ];
        routes = [
          {
            Destination = homelabPrefix;
            Gateway = hostAddress;
          }
        ];
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
        };
      };

      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_17;
        enableTCPIP = true;
        initdbArgs = [ "--data-checksums" ];
        ensureDatabases = [ "vaultwarden" ];
        ensureUsers = [
          {
            name = "vaultwarden";
            ensureDBOwnership = true;
          }
        ];
        authentication = lib.mkForce authentication;
        settings = {
          listen_addresses = lib.mkForce postgresAddress;
          password_encryption = "scram-sha-256";
          ssl = true;
          ssl_min_protocol_version = "TLSv1.3";
          ssl_cert_file = "/run/postgresql-tls/server.crt";
          ssl_key_file = "/run/postgresql-tls/server.key";
          log_connections = true;
          log_disconnections = true;
        };
      };

      systemd.services.postgresql.unitConfig.RequiresMountsFor = lib.mkForce [
        config.services.postgresql.dataDir
        "/run/postgresql-tls"
      ];

      systemd.services.postgresql-vaultwarden-role =
        let
          setPassword = pkgs.writeShellApplication {
            name = "set-vaultwarden-postgresql-password";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.util-linux
              config.services.postgresql.package
            ];
            text = builtins.readFile ./postgresql/set-vaultwarden-password.sh;
          };
        in
        {
          description = "Apply the runtime Vaultwarden PostgreSQL password";
          wantedBy = [ "multi-user.target" ];
          requires = [ "postgresql-setup.service" ];
          after = [ "postgresql-setup.service" ];
          unitConfig.RequiresMountsFor = "/run/vaultwarden-credentials";
          environment.PASSWORD_FILE = "/run/vaultwarden-credentials/postgresql.password";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe setPassword;
          };
        };

      networking.nftables.enable = true;
      networking.firewall = {
        enable = true;
        extraInputRules = ''
          ip6 saddr { ${vaultwardenAddress}/128, ${hostAddress}/128, ${homelabPrefix} } \
            tcp dport 5432 accept
          ip6 saddr ${hostAddress}/128 tcp dport 9100 accept
        '';
      };

      services.journald.extraConfig = ''
        ForwardToConsole=yes
        TTYPath=/dev/console
        MaxLevelConsole=notice
      '';
    };
}
