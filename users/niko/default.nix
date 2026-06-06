{ pkgs, ... }:

{
  imports = [ ../. ];

  users.users.niko = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.fish;
  };

  home-manager.users.niko = import ./home.nix;
}
