{ pkgs, ... }:

{
  home.packages = [ pkgs.kicad ];

  # These are portable UI preferences from KiCad 10. Project libraries and
  # plugin packages stay with their respective projects, rather than becoming
  # machine-wide Home Manager state.
  xdg.configFile = {
    "kicad/10.0/user.hotkeys".source = ./config/10.0/user.hotkeys;
    "kicad/10.0/colors" = {
      source = ./config/10.0/colors;
      recursive = true;
    };
    "kicad/10.0/toolbars" = {
      source = ./config/10.0/toolbars;
      recursive = true;
    };
  };
}
