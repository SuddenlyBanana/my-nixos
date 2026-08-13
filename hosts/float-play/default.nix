{ ... }:

{
  imports = [
    ../../modules/server
    ./boot.nix
    ./filesystem.nix
    ./hardware.nix
    ./networking.nix
    ./modules/server
  ];

  networking.hostName = "float-play";

  time.timeZone = "UTC";

  system.stateVersion = "26.05";
}
