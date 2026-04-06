{ pkgs, ... }:

{
  programs.starship = {
    enable = true;
    settings = pkgs.lib.importTOML ./catppuccin-powerline.toml;
  };
}
