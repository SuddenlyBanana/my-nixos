{ pkgs, secrets, ... }:

let
  serviceAddress = "${secrets.privateIps.prefixes.homelabUla}:9::11";
  serviceHostAddress = "${secrets.privateIps.prefixes.homelabUla}:9::1";
  databaseAddress = "${secrets.privateIps.prefixes.homelabUla}:200::11";
  databaseHostAddress = "${secrets.privateIps.prefixes.homelabUla}:200::1";
  postgresAddress = "${secrets.privateIps.prefixes.homelabUla}:200::10";
  openbaoAddress = "${secrets.privateIps.prefixes.homelabUla}:200::21";
  floatPlayAddress = secrets.privateIps.float-play.v6;
  dataImage = "/srv/media/services/vaultwarden/data.raw";
  openbaoCaImage = "/srv/media/services/openbao/ca.raw";
  approleDirectory = "/var/lib/vaultwarden/approle/vaultwarden";
  serviceMacAddress = "02:00:00:00:01:11";
  databaseMacAddress = "02:00:00:02:00:11";
  port = 8222;

  credentialTemplate = pkgs.replaceVars ./vaultwarden/vaultwarden.env.ctmpl {
    POSTGRES_ADDRESS = postgresAddress;
  };

  openbaoAgentConfig = pkgs.replaceVars ./vaultwarden/openbao-agent.hcl {
    OPENBAO_ADDRESS = openbaoAddress;
    TEMPLATE_SOURCE = credentialTemplate;
  };
in
{
  # Keep the admin-token generation utility available on the host.
  environment.systemPackages = [
    pkgs.libargon2
    pkgs.rsync
    pkgs.sqlite
  ];

  microvm.vms.vaultwarden.config =
    {
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        ./operator-access.nix
        (import ./openbao-approle-agent.nix {
          name = "vaultwarden";
          credentialsDirectory = approleDirectory;
          runUser = "openbao-agent";
          runGroup = "vaultwarden";
          agentConfig = openbaoAgentConfig;
          caCert = "/etc/openbao-ca/ca.crt";
        })
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
            image = openbaoCaImage;
            mountPoint = "/etc/openbao-ca";
            size = 16;
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

      users.users.openbao-agent = {
        isSystemUser = true;
        group = "vaultwarden";
      };

      systemd.services.openbao-agent-vaultwarden = {
        serviceConfig = {
          RuntimeDirectory = "vaultwarden-secrets";
          RuntimeDirectoryMode = "0750";
        };
      };

      systemd.tmpfiles.settings."10-vaultwarden-approle"."${approleDirectory}".d = {
        user = "openbao-agent";
        group = "vaultwarden";
        mode = "0700";
      };

      services.vaultwarden = {
        enable = true;
        dbBackend = "postgresql";
        environmentFile = "/run/vaultwarden-secrets/vaultwarden.env";
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
        wants = [ "openbao-agent-vaultwarden.service" ];
        after = [ "openbao-agent-vaultwarden.service" ];
        unitConfig.RequiresMountsFor = [
          "/var/lib/vaultwarden"
          "/etc/openbao-ca"
        ];
        unitConfig.ConditionPathExists = "/run/vaultwarden-secrets/vaultwarden.env";
        serviceConfig = {
          ReadWritePaths = [ "/var/lib/vaultwarden" ];
          EnvironmentFile = lib.mkAfter [ "-/var/lib/vaultwarden/admin.env" ];
        };
      };

      systemd.paths.vaultwarden-credential-refresh = {
        description = "Watch the OpenBao-rendered Vaultwarden credential";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = "/run/vaultwarden-secrets/vaultwarden.env";
          Unit = "vaultwarden-credential-refresh.service";
        };
      };

      systemd.services.vaultwarden-credential-refresh = {
        description = "Restart Vaultwarden after a database credential update";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe' pkgs.systemd "systemctl"} restart vaultwarden.service";
        };
      };

      networking.nftables.enable = true;
      networking.firewall = {
        enable = true;
        extraInputRules = ''
          ip6 saddr { ${floatPlayAddress}/128, ${serviceHostAddress}/128 } \
            tcp dport ${toString port} accept
          ip6 saddr ${databaseHostAddress}/128 tcp dport { 22, 9100 } accept
        '';
      };

      services.journald.extraConfig = ''
        ForwardToConsole=yes
        TTYPath=/dev/console
        MaxLevelConsole=notice
      '';
    };
}
