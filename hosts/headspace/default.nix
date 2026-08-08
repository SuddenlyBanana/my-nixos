{ ... }:

{
  imports = [
    ../../modules/desktop
    ./boot.nix
    ./filesystem.nix
    ./hardware.nix
    ./graphics.nix
    ./modules/desktop

    # broken / requires linux 6.6 LTS or earlier
    # ./nvidia-proprietary.nix
  ];

  networking.hostName = "headspace";

  time.timeZone = "Europe/Warsaw";

  i18n = {
    defaultLocale = "pl_PL.UTF-8";
    extraLocaleSettings = { LC_MESSAGES = "en_US.UTF-8"; };
  };

  system.stateVersion = "25.11";
}
