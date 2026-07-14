{ ... }:

{
  imports = [
    ../.
    ./hardware.nix
    ./modules/server
  ];

  networking.hostName = "relayouter";

  time.timeZone = "UTC";

  system.stateVersion = "26.05";
}
