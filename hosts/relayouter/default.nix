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

  networking.hostName = "relayouter";

  time.timeZone = "UTC";

  system.stateVersion = "26.05";
}
