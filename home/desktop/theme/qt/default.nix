{ hyprqt6engine, pkgs, ... }:

let
  # Keep the complete plugin dependency chain on Nixpkgs' GCC 15.  The
  # upstream flake currently builds its engine and Hypr libraries with GCC 16,
  # which Qt applications cannot load into their GCC-15 process.
  hyprutils = hyprqt6engine.inputs.hyprutils.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
    stdenv = pkgs.gcc15Stdenv;
  };
  hyprlang = hyprqt6engine.inputs.hyprlang.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
    stdenv = pkgs.gcc15Stdenv;
    inherit hyprutils;
  };
  engine = hyprqt6engine.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
    stdenv = pkgs.gcc15Stdenv;
    inherit hyprlang hyprutils;
  };
  kvantum = pkgs.qt6Packages.qtstyleplugin-kvantum;
  catppuccinKde = pkgs.catppuccin-kde.override {
    flavour = [ "macchiato" ];
    accents = [ "blue" ];
  };
  catppuccinKvantum = pkgs.catppuccin-kvantum.override {
    variant = "macchiato";
    accent = "blue";
  };
in {
  home.packages = [
    engine
    catppuccinKde
    catppuccinKvantum
    kvantum
  ];

  # The engine reads a native config; UWSM must receive the platform theme
  # before it launches any Qt applications.
  xdg.configFile."hypr/hyprqt6engine.conf".source = ./hyprqt6engine.conf;
  xdg.configFile."Kvantum/kvantum.kvconfig".source = ./kvantum.kvconfig;
  xdg.configFile."Kvantum/catppuccin-macchiato-blue".source =
    "${catppuccinKvantum}/share/Kvantum/catppuccin-macchiato-blue";
  xdg.configFile."uwsm/env".text = ''
    export QT_QPA_PLATFORMTHEME=hyprqt6engine
    export QT_PLUGIN_PATH=${engine}/lib/qt-6:${kvantum}/lib/qt-6
  '';
  xdg.dataFile."color-schemes/CatppuccinMacchiatoBlue.colors".source =
    "${catppuccinKde}/share/color-schemes/CatppuccinMacchiatoBlue.colors";
}
