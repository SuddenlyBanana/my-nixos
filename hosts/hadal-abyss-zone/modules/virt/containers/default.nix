{ config, lib, pkgs, ... }:

let
  containers = lib.filterAttrs (
    _: container:
    container.imageFile == null
    && container.imageStream == null
    && container.pull != "never"
  ) config.virtualisation.oci-containers.containers;
  updateServiceName = name: "oci-image-update-${name}";
  imageUpdater = pkgs.writeShellApplication {
    name = "update-container-image";
    runtimeInputs = [ pkgs.coreutils pkgs.podman pkgs.systemd pkgs.util-linux ];
    text = builtins.readFile ./update-container-image.sh;
  };
in {
  imports = [ ./www-domain1.nix ];

  virtualisation = {
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };
    oci-containers.backend = "podman";
  };

  systemd.services = lib.mapAttrs' (name: container:
    let
      rootless = container.podman.user != "root";
    in lib.nameValuePair (updateServiceName name) {
      description = "Update the ${name} container image";
      after = [ "network-online.target" ] ++ lib.optionals rootless [ "linger-users.service" ];
      wants = [ "network-online.target" ] ++ lib.optionals rootless [ "linger-users.service" ];
      path = lib.optionals rootless [ "/run/wrappers" ];
      environment = {
        CONTAINER_UPDATE_USER = container.podman.user;
        CONTAINER_UPDATE_IMAGE = container.image;
        CONTAINER_UPDATE_SERVICE = "${container.serviceName}.service";
        CONTAINER_UPDATE_NAME = name;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${imageUpdater}/bin/update-container-image";
      };
    }
  ) containers;

  systemd.timers = lib.mapAttrs' (name: _:
    lib.nameValuePair (updateServiceName name) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "minutely";
        AccuracySec = "1s";
        Persistent = true;
      };
    }
  ) containers;
}
