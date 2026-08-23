{ config, pkgs, ... }:

let
  catppuccinGtk = pkgs.catppuccin-gtk.override {
    variant = "macchiato";
    accents = [ "blue" ];
  };
in {
  gtk = {
    enable = true;
    font = {
      name = "JetBrainsMono Nerd Font";
      size = 10;
    };
    theme = {
      name = "catppuccin-macchiato-blue-standard";
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
    gtk3.extraCss = ''
      * { font-weight: normal; }
    '';
  };

  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";
}
