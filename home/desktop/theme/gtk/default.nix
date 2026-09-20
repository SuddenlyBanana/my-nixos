{ config, pkgs, ... }:

let
  catppuccinGtk = pkgs.catppuccin-gtk.override {
    variant = "macchiato";
    accents = [ "mauve" ];
  };
  themeName = "catppuccin-macchiato-mauve-standard";
in {
  gtk = {
    enable = true;
    font = {
      name = "JetBrainsMono Nerd Font";
      size = 10;
    };
    theme = {
      name = themeName;
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

  # The Settings portal advertises the theme name, but Flatpak also needs
  # access to the theme and to Home Manager's symlinked GTK config files.
  # Home Manager links these through its generation in /nix/store.
  home.file.".themes/${themeName}".source = "${catppuccinGtk}/share/themes/${themeName}";
  services.flatpak.overrides.global.Context.filesystems = [
    "~/.themes:ro"
    "xdg-config/gtk-3.0:ro"
    "xdg-config/gtk-4.0:ro"
    "/nix/store:ro"
  ];
}
