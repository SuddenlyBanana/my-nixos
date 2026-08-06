{ ... }:

{
  imports = [
    ../../modules/server
    ./boot.nix
    ./filesystem.nix
    ./hardware.nix
    ./networking.nix
    ./modules/server
    ./modules/virt
  ];

  networking.hostName = "hadal-abyss-zone";

  time.timeZone = "Europe/Warsaw";

  system.stateVersion = "26.05";
}
