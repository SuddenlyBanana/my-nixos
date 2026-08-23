{ config, pkgs, ... }:

let
  catppuccinGtk = pkgs.catppuccin-gtk.override {
    variant = "macchiato";
    accents = [ "mauve" ];
  };
in {
  gtk = {
    enable = true;
    font = {
      name = "JetBrainsMono Nerd Font";
      size = 10;
    };
    theme = {
      name = "catppuccin-macchiato-mauve-standard";
      package = catppuccinGtk;
    };
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
    cursorTheme = {
      name = "mikucursor";
      size = 32;
    };
    gtk4.theme = config.gtk.theme;
  };

  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";
}
