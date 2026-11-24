{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  cfg = config.hadal.microvms.rke2.gitops;
  topology = import ../../topology.nix { inherit secrets; };
  components =
    pkgs.runCommand "flux-components.yaml"
      {
        nativeBuildInputs = [
          pkgs.fluxcd
          pkgs.kustomize
        ];
      }
      ''
            export HOME="$TMPDIR"
        flux install --export --network-policy=true > flux.yaml
        cp ${./components/kustomization.yaml} kustomization.yaml
        kustomize build . > "$out"
      '';
  sync = pkgs.replaceVars ./sync.yaml.in {
    GIT_URL = cfg.url;
    GIT_BRANCH = cfg.branch;
    GIT_PATH = cfg.path;
  };
  bootstrap = pkgs.writeShellApplication {
    name = "bootstrap-hadal-flux";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.kubectl
    ];
    runtimeEnv = {
      FLUX_COMPONENTS = components;
      FLUX_SYNC = sync;
      POSTGRES_ADDRESS = topology.infrastructure.postgresqlAddress;
      OPENBAO_ADDRESS = topology.infrastructure.openbaoAddress;
      VAULTWARDEN_HOST = "vault.${secrets.zones.float-play.windowsMoeZone.name}";
      STALWART_PROXY_ADDRESS = secrets.privateIps.float-play.v6;
      KUBERNETES_API = "https://[${topology.service.rke2Address}]:6443";
    };
    text = builtins.readFile ./bootstrap.sh;
  };
  checkCredentials = pkgs.writeShellApplication {
    name = "check-hadal-flux-credentials";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = builtins.readFile ./check-credentials.sh;
  };
in
{
  options.hadal.microvms.rke2.gitops = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Bootstrap pinned Flux controllers and the GitOps root automatically; never write to the Git remote.";
    };
    url = lib.mkOption {
      type = lib.types.strMatching "ssh://[^[:space:]]+";
      default = "ssh://git@github.com/SuddenlyBanana/hadal-abyss-zone-gitops.git";
      description = "Read-only SSH Git remote for Flux.";
    };
    branch = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_./-]+";
      default = "main";
    };
    path = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_./-]+";
      default = "./clusters/hadal";
    };
  };

  config = lib.mkIf (config.hadal.microvms.rke2.enable && cfg.enable) {
    microvm.vms.rke2.config = {
      systemd.services.hadal-flux-credentials = {
        serviceConfig = {
          Type = "oneshot";
          UMask = "0077";
          ExecStart = lib.getExe checkCredentials;
        };
      };
      systemd.timers.hadal-flux-credentials = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "5min";
        };
      };
      environment.systemPackages = [ pkgs.fluxcd ];
      systemd.services.hadal-flux-bootstrap = {
        description = "Install pinned Flux and reconcile the configured read-only Git remote";
        wantedBy = [ "multi-user.target" ];
        requires = [ "rke2-server.service" ];
        after = [ "rke2-server.service" ];
        unitConfig.StartLimitIntervalSec = 0;
        restartTriggers = [
          components
          sync
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = "30s";
          TimeoutStartSec = "15min";
          UMask = "0077";
          RuntimeDirectory = "hadal-flux-bootstrap";
          LoadCredential = [
            "identity:/run/hadal-bootstrap/flux-ssh-key"
            "known_hosts:/run/hadal-bootstrap/flux-known-hosts"
            "ca.crt:/run/hadal-bootstrap/ca.crt"
          ];
          ExecStart = lib.getExe bootstrap;
        };
      };
    };
  };
}
