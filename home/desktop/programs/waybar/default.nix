{ lib, pkgs, ... }:

let
  pavucontrol = lib.getExe' pkgs.pavucontrol "pavucontrol";
  nmConnectionEditor = lib.getExe' pkgs.networkmanagerapplet "nm-connection-editor";
  swayncClient = lib.getExe' pkgs.swaynotificationcenter "swaync-client";
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
      "modules-right" = [ "pulseaudio" "network" "battery" "clock" "custom/notification" "tray" ];
      pulseaudio.on-click = pavucontrol;
      network.on-click = nmConnectionEditor;
      clock.format = "{:%a, %d %b  %H:%M}";
      battery.format = "{capacity}% {icon}";
      battery.format-icons = [ "󰂎" "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
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
