{ ... }:

{
  imports = [
    ../.
    ./boot.nix
    ./filesystem.nix
    ./hardware.nix
    ./graphics.nix

    # broken / requires linux 6.6 LTS or earlier
    # ./nvidia-proprietary.nix
  ];

  networking.hostName = "nixbanana";
}
