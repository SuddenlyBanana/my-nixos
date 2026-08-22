{ pkgs, ... }:

{
  imports = [ ./hyprlock ./waybar ./wofi ];

  home.packages = with pkgs; [
    pavucontrol
    networkmanagerapplet
    kdePackages.dolphin
    kdePackages.ark
    kdePackages.konsole
    satty
    hyprpicker
    shared-mime-info
    xdg-utils
    cliphist
    wl-clipboard
    wayshot
    brightnessctl
    playerctl
    hyprpwcenter
    hyprshutdown
    hyprsysteminfo
    hyprland-qt-support
  ];
}
