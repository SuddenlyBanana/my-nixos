{ pkgs, ... }:

{
  imports = [ ./hyprland ./kitty ./git ./helix ./starship ];

  home = {
    username = "niko";
    homeDirectory = "/home/niko";
    stateVersion = "25.11";
    packages = with pkgs; [ wimlib ];
  };
}
