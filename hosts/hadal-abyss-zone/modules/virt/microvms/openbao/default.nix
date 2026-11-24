{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  cfg = config.hadal.microvms.openbao;
  topology = import ../topology.nix { inherit secrets; };
  approleDirectory = "/run/hadal-bootstrap";
  macAddress = "02:00:00:02:00:21";

  certificateTemplate = pkgs.replaceVars ./server.pem.ctmpl {
    OPENBAO_ADDRESS = topology.infrastructure.openbaoAddress;
  };

  openbaoAgentConfig = pkgs.replaceVars ./openbao-agent.hcl {
    TEMPLATE_SOURCE = certificateTemplate;
  };

  prepareTls = pkgs.writeShellApplication {
    name = "prepare-openbao-tls";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      pkgs.openssl
      pkgs.diffutils
    ];
    text = builtins.readFile ./prepare-tls.sh;
  };
in
{
  options.hadal.microvms.openbao = {
    enable = lib.mkEnableOption "the external OpenBao MicroVM";

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start OpenBao automatically after the production LV is available.";
    };

    dataDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/hadal-vm/openbao-data";
      description = "Raw host block device containing the XFS OpenBao data filesystem.";
    };

  };

  config = lib.mkIf cfg.enable {
    microvm.vms.openbao = {
      inherit (cfg) autostart;
      config =
        { lib, pkgs, ... }:
        {
          imports = [
            (import ../guest-base.nix {
              hostName = "openbao";
              address = topology.infrastructure.openbaoAddress;
              hostAddress = topology.infrastructure.hostAddress;
              inherit macAddress;
              tapId = "vm-db-04";
              vsockCid = 21;
              mem = 1024;
              vcpu = 2;
              bootstrapShare = true;
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
                  mountPoint = "/var/lib/openbao";
                  label = "openbao-data";
                  size = 32768;
                  fsType = "xfs";
                  autoCreate = false;
                  direct = true;
                }
              ];
            })
            (import ../openbao-approle-agent.nix {
              name = "openbao-tls";
              credentialsDirectory = approleDirectory;
              runUser = "openbao";
              runGroup = "openbao";
              agentConfig = openbaoAgentConfig;
              caCert = "/run/hadal-bootstrap/ca.crt";
            })
            (import ../managed-tls.nix {
              name = "openbao";
              bundlePath = "/var/lib/openbao/tls-staging/bundle.pem";
              outputDir = "/var/lib/openbao/tls";
              owner = "openbao";
              group = "openbao";
              serverName = "openbao.infra.windows.moe";
              serviceUnit = "openbao.service";
              caCert = "/run/hadal-bootstrap/ca.crt";
            })
          ];

          users.groups.openbao = { };
          users.users.openbao = {
            isSystemUser = true;
            group = "openbao";
            home = "/var/lib/openbao";
          };

          services.openbao = {
            enable = true;
            settings = {
              ui = false;
              disable_mlock = true;
              audit = [
                {
                  file.file = {
                    description = "Hadal service audit log";
                    options = {
                      file_path = "/var/lib/openbao/audit/audit.json";
                      log_raw = "false";
                    };
                  };
                }
              ];
              api_addr = "https://[${topology.infrastructure.openbaoAddress}]:8200";
              cluster_addr = "https://[${topology.infrastructure.openbaoAddress}]:8201";
              storage.raft = {
                path = "/var/lib/openbao";
                node_id = "openbao-hadal-1";
              };
              listener.default = {
                type = "tcp";
                address = "[${topology.infrastructure.openbaoAddress}]:8200";
                cluster_address = "[${topology.infrastructure.openbaoAddress}]:8201";
                tls_cert_file = "/var/lib/openbao/tls/current/server.crt";
                tls_key_file = "/var/lib/openbao/tls/current/server.key";
                tls_disable_client_certs = false;
                tls_min_version = "tls13";
              };
              listener.recovery = {
                type = "tcp";
                address = "[::1]:8202";
                tls_cert_file = "/var/lib/openbao/recovery-tls/server.crt";
                tls_key_file = "/var/lib/openbao/recovery-tls/server.key";
                tls_disable_client_certs = false;
                tls_min_version = "tls13";
              };
            };
          };

          environment.variables = {
            BAO_ADDR = "https://[${topology.infrastructure.openbaoAddress}]:8200";
            BAO_CACERT = "/run/hadal-bootstrap/ca.crt";
            OPENBAO_ADDRESS = topology.infrastructure.openbaoAddress;
            POSTGRESQL_ADDRESS = topology.infrastructure.postgresqlAddress;
          };

          environment.systemPackages = [
            (pkgs.writeShellApplication {
              name = "bootstrap-openbao-pki";
              runtimeInputs = [
                pkgs.coreutils
                pkgs.jq
                pkgs.openbao
                pkgs.openssl
              ];
              text = builtins.readFile ./bootstrap-pki.sh;
            })
          ];

          environment.etc = {
            "openbao-bootstrap/backup-policy.hcl".source = ./backup-policy.hcl;
            "openbao-bootstrap/openbao-tls-policy.hcl".source = ./openbao-tls-policy.hcl;
            "openbao-bootstrap/postgresql-tls-policy.hcl".source = ./postgresql-tls-policy.hcl;
          };
          systemd.tmpfiles.settings."10-openbao-audit"."/var/lib/openbao/audit".d = {
            user = "openbao";
            group = "openbao";
            mode = "0700";
          };

          systemd.services.openbao-tls-permissions = {
            description = "Prepare the OpenBao TLS volume";
            requiredBy = [ "openbao.service" ];
            before = [ "openbao.service" ];
            unitConfig.RequiresMountsFor = [
              "/var/lib/openbao"
              "/run/hadal-bootstrap"
            ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe prepareTls;
            };
          };

          systemd.services.openbao = {
            requires = [ "openbao-tls-permissions.service" ];
            after = [ "openbao-tls-permissions.service" ];
            unitConfig.RequiresMountsFor = [
              "/var/lib/openbao"
              "/run/hadal-bootstrap"
            ];
            serviceConfig.DynamicUser = lib.mkForce false;
          };

          systemd.services.openbao-agent-openbao-tls = {
            wants = [ "openbao.service" ];
            after = [ "openbao.service" ];
          };

          networking.firewall.extraInputRules = ''
            ip6 saddr { ${topology.infrastructure.hostAddress}/128, ${topology.infrastructure.postgresqlAddress}/128, ${topology.service.rke2Address}/128, ${topology.cluster.podCidr} } \
              tcp dport 8200 accept
            ip6 saddr ${topology.infrastructure.hostAddress}/128 tcp dport 22 accept
          '';
        };
    };

    systemd.services."microvm@openbao".unitConfig.ConditionPathIsBlockDevice = cfg.dataDevice;
  };
}
