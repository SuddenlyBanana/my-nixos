{ config, secrets, ... }:

let
  siteUser = "www-domain1";
  siteUid = 20000;
  siteHome = "/var/lib/www-domain1";
  siteRuntimeDir = "/run/user/${toString siteUid}";
  siteContainer = "www-domain1";
  siteNetworkService = "podman-network-www-domain1_default";
  siteContainerService = "podman-${siteContainer}";
in {
  imports = [ ./www-domain1-generated.nix ];

  age.secrets.ghcr-www-domain1 = {
    file = secrets.paths."ghcr-www-domain1";
    owner = siteUser;
    mode = "0400";
  };

  users.groups.${siteUser}.gid = siteUid;
  users.users.${siteUser} = {
    isSystemUser = true;
    uid = siteUid;
    group = siteUser;
    home = siteHome;
    createHome = true;
    autoSubUidGidRange = true;
    linger = true;
  };

  virtualisation.oci-containers.containers.${siteContainer} = {
    podman.user = siteUser;
    environment.SITE_HOST = "www.${secrets.zones.float-play.domain1.name}";
    login = {
      registry = "ghcr.io";
      username = "SuddenlyBanana";
      passwordFile = config.age.secrets.ghcr-www-domain1.path;
    };
  };

  # compose2nix creates the named network as a separate system service. It must
  # use the same rootless Podman storage as the container.
  systemd.services.${siteNetworkService} = {
    after = [ "linger-users.service" "user@${toString siteUid}.service" ];
    wants = [ "linger-users.service" "user@${toString siteUid}.service" ];
    path = [ "/run/wrappers" ];
    environment = {
      HOME = siteHome;
      XDG_RUNTIME_DIR = siteRuntimeDir;
    };
    unitConfig.RequiresMountsFor = "${siteRuntimeDir}/containers";
    serviceConfig = {
      User = siteUser;
      Group = siteUser;
    };
  };

  systemd.services.${siteContainerService} = {
    after = [ "user@${toString siteUid}.service" ];
    wants = [ "user@${toString siteUid}.service" ];
    path = [ "/run/wrappers" ];
    environment.XDG_RUNTIME_DIR = siteRuntimeDir;
  };
}
