{ ... }:

{
  imports = [ ./unifi.nix ];

  virtualisation = {
    podman = {
      enable = true;
      dockerCompat = true;
    };
    oci-containers.backend = "podman";
  };
}
