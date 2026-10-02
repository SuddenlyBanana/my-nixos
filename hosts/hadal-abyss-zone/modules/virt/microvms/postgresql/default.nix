{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  cfg = config.hadal.microvms.postgresql;
  topology = import ../topology.nix { inherit secrets; };
  legacyVaultwardenAddress = "${secrets.privateIps.prefixes.homelabUla}:200::11";
  approleDirectory = "/var/lib/postgresql/approle/postgresql-tls";
  macAddress = "02:00:00:02:00:10";

  certificateTemplate = pkgs.replaceVars ./server.pem.ctmpl {
    POSTGRES_ADDRESS = topology.infrastructure.postgresqlAddress;
  };

  openbaoAgentConfig = pkgs.replaceVars ./openbao-agent.hcl {
    OPENBAO_ADDRESS = topology.infrastructure.openbaoAddress;
    TEMPLATE_SOURCE = certificateTemplate;
  };

  authentication =
    lib.replaceStrings
      [
        "@VAULTWARDEN_ADDRESS@"
        "@RKE2_ADDRESS@"
        "@POD_CIDR@"
        "@OPENBAO_ADDRESS@"
        "@HOST_ADDRESS@"
        "@HOMELAB_PREFIX@"
      ]
      [
        "${legacyVaultwardenAddress}/128"
        "${topology.service.rke2Address}/128"
        topology.cluster.podCidr
        "${topology.infrastructure.openbaoAddress}/128"
        "${topology.infrastructure.hostAddress}/128"
        secrets.privateIps.subnets.homelabLan
      ]
      (builtins.readFile ./pg_hba.conf);
in
{
  options.hadal.microvms.postgresql = {
    enable = lib.mkEnableOption "the external PostgreSQL MicroVM";

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start PostgreSQL automatically after the production LV is available.";
    };

    dataDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/hadal-vm/postgresql-data";
      description = "Raw host block device containing the XFS PostgreSQL data filesystem.";
    };

    openbaoCaImage = lib.mkOption {
      type = lib.types.str;
      default = "/srv/media/services/openbao/ca.raw";
      description = "Read-only bootstrap volume containing the OpenBao CA certificate.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.pgloader
      pkgs.postgresql_17
    ];

    microvm.vms.postgresql = {
      inherit (cfg) autostart;
      config =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          imports = [
            (import ../guest-base.nix {
              hostName = "postgresql";
              address = topology.infrastructure.postgresqlAddress;
              hostAddress = topology.infrastructure.hostAddress;
              inherit macAddress;
              tapId = "vm-db-01";
              vsockCid = 20;
              mem = 2048;
              vcpu = 2;
              routes = [
                {
                  Destination = topology.service.prefix;
                  Gateway = topology.infrastructure.hostAddress;
                }
                {
                  Destination = topology.cluster.podCidr;
                  Gateway = topology.infrastructure.hostAddress;
                }
                {
                  Destination = secrets.privateIps.subnets.homelabLan;
                  Gateway = topology.infrastructure.hostAddress;
                }
              ];
              volumes = [
                {
                  image = cfg.dataDevice;
                  mountPoint = "/var/lib/postgresql";
                  label = "postgresql-data";
                  size = 131072;
                  fsType = "xfs";
                  autoCreate = false;
                  direct = true;
                }
                {
                  image = cfg.openbaoCaImage;
                  mountPoint = "/etc/openbao-ca";
                  size = 16;
                  fsType = "ext4";
                  autoCreate = false;
                  readOnly = true;
                }
              ];
            })
            (import ../openbao-approle-agent.nix {
              name = "postgresql-tls";
              credentialsDirectory = approleDirectory;
              runUser = "postgres";
              runGroup = "postgres";
              agentConfig = openbaoAgentConfig;
              caCert = "/etc/openbao-ca/ca.crt";
            })
            (import ../managed-tls.nix {
              name = "postgresql";
              bundlePath = "/var/lib/postgresql/tls-staging/bundle.pem";
              outputDir = "/var/lib/postgresql/tls";
              owner = "postgres";
              group = "postgres";
              serverName = "postgres.home.arpa";
              serviceUnit = "postgresql.service";
              startUnit = "postgresql.target";
            })
          ];

          environment.systemPackages = [ pkgs.openssl ];

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
              {
                name = "openbao";
                ensureClauses.createrole = true;
              }
            ];
            authentication = lib.mkForce authentication;
            settings = {
              listen_addresses = lib.mkForce topology.infrastructure.postgresqlAddress;
              password_encryption = "scram-sha-256";
              ssl = true;
              ssl_min_protocol_version = "TLSv1.3";
              ssl_cert_file = "/var/lib/postgresql/tls/current/server.crt";
              ssl_key_file = "/var/lib/postgresql/tls/current/server.key";
              log_connections = true;
              log_disconnections = true;
            };
          };

          systemd.services.postgresql.unitConfig = {
            RequiresMountsFor = lib.mkForce [ config.services.postgresql.dataDir ];
            ConditionPathExists = [
              "/var/lib/postgresql/tls/current/server.crt"
              "/var/lib/postgresql/tls/current/server.key"
            ];
          };

          systemd.targets.postgresql.wantedBy = lib.mkForce [ ];

          systemd.tmpfiles.settings."10-postgresql-managed-tls" = {
            "${approleDirectory}".d = {
              user = "postgres";
              group = "postgres";
              mode = "0700";
            };
            "/var/lib/postgresql/tls-staging".d = {
              user = "postgres";
              group = "postgres";
              mode = "0700";
            };
            "/var/lib/postgresql/tls".d = {
              user = "postgres";
              group = "postgres";
              mode = "0700";
            };
          };

          systemd.services.postgresql-openbao-role = {
            description = "Allow OpenBao to manage Vaultwarden dynamic roles";
            wantedBy = [ "postgresql.target" ];
            requires = [ "postgresql-setup.service" ];
            after = [ "postgresql-setup.service" ];
            serviceConfig = {
              Type = "oneshot";
              User = "postgres";
              Group = "postgres";
              ExecStart = "${lib.getExe' config.services.postgresql.package "psql"} --dbname=postgres --set=ON_ERROR_STOP=1 --command=\"GRANT vaultwarden TO openbao WITH ADMIN OPTION\"";
            };
          };

          networking.firewall.extraInputRules = ''
            ip6 saddr { ${legacyVaultwardenAddress}/128, ${topology.service.rke2Address}/128, ${topology.cluster.podCidr}, ${topology.infrastructure.openbaoAddress}/128, ${topology.infrastructure.hostAddress}/128, ${secrets.privateIps.subnets.homelabLan} } \
              tcp dport 5432 accept
            ip6 saddr ${topology.infrastructure.hostAddress}/128 tcp dport 22 accept
          '';
        };
    };

    systemd.services."microvm@postgresql".unitConfig.ConditionPathIsBlockDevice = cfg.dataDevice;
  };
}
