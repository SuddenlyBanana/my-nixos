{ pkgs, ... }:

{
  imports = [ ./hyprlock ./waybar ./wofi ];

  home.packages = with pkgs; [
    pavucontrol
    xfce4-power-manager
    caffeine-ng
    networkmanagerapplet
    kdePackages.dolphin
    kdePackages.ark
    kdePackages.konsole
    kdePackages.kservice
    kdePackages.gwenview
    kdePackages.okular
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
