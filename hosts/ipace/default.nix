{ ... }:

{
  imports = [
    ./boot.nix
    ./filesystem.nix
    ./hardware.nix
    ./networking.nix
    ./sd-image.nix
    ./modules
  ];

  networking.hostName = "ipace";

  time.timeZone = "Europe/Warsaw";

  system.stateVersion = "26.05";
}
