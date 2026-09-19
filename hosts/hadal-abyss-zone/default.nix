{ ... }:

{
  imports = [
    ./boot.nix
    ./filesystem.nix
    ./storage.nix
    ./hardware.nix
    ./networking.nix
    ./power.nix
    ./modules/server
    ./modules/virt
  ];

  networking.hostName = "hadal-abyss-zone";

  services.openssh = {
    openFirewall = false;
    settings = {
      AllowUsers = [ "workspace" ];
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  time.timeZone = "Europe/Warsaw";

  system.stateVersion = "26.05";
}
