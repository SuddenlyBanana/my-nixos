{ lib, pkgs, ... }:

let
  pavucontrol = lib.getExe' pkgs.pavucontrol "pavucontrol";
  nmConnectionEditor = lib.getExe' pkgs.networkmanagerapplet "nm-connection-editor";
  swayncClient = lib.getExe' pkgs.swaynotificationcenter "swaync-client";
  powerProfile = pkgs.writeShellApplication {
    name = "waybar-power-profile";
    runtimeInputs = [ pkgs.tlp-pd pkgs.wofi ];
    text = builtins.readFile ./power-profile.sh;
  };
in {
  programs.waybar = {
    enable = true;
    systemd.enable = true;
    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 30;
      spacing = 8;
      "modules-left" = [ "hyprland/workspaces" ];
      "modules-center" = [ "hyprland/window" ];
      "modules-right" = [ "pulseaudio" "network" "battery" "custom/power-profile" "clock" "custom/notification" "tray" ];
      pulseaudio.on-click = pavucontrol;
      network.on-click = nmConnectionEditor;
      clock.format = "{:%a, %d %b  %H:%M}";
      battery.format = "{capacity}% {icon}";
      battery.format-icons = [ "󰂎" "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
      "custom/power-profile" = {
        return-type = "json";
        exec = "${powerProfile}/bin/waybar-power-profile status";
        interval = 5;
        tooltip = true;
        on-click = "${powerProfile}/bin/waybar-power-profile choose";
        on-click-right = "${powerProfile}/bin/waybar-power-profile cycle";
      };
      "custom/notification" = {
        tooltip = true;
        tooltip-format = "Left click: notifications\nRight click: Do Not Disturb";
        format = "{icon}";
        format-icons = {
          notification = "󱅫";
          none = "󰂜";
          dnd-notification = "󰂠";
          dnd-none = "󰪓";
          inhibited-notification = "󰂛";
          inhibited-none = "󰪑";
          dnd-inhibited-notification = "󰂛";
          dnd-inhibited-none = "󰪑";
        };
        return-type = "json";
        exec = "${swayncClient} -swb";
        on-click = "${swayncClient} -t -sw";
        on-click-right = "${swayncClient} -d -sw";
        escape = true;
      };
    };
  };
}
