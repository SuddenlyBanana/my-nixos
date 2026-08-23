{ config, lib, pkgs, ... }:

let
  hyprlock = lib.getExe pkgs.hyprlock;
  wofi = lib.getExe pkgs.wofi;
  cliphist = lib.getExe pkgs.cliphist;
  wlPaste = lib.getExe' pkgs.wl-clipboard "wl-paste";
  wlCopy = lib.getExe' pkgs.wl-clipboard "wl-copy";
  wayshot = lib.getExe pkgs.wayshot;
  hyprshutdown = lib.getExe pkgs.hyprshutdown;
  kitty = lib.getExe pkgs.kitty;
  dolphin = lib.getExe pkgs.kdePackages.dolphin;
  brightnessctl = lib.getExe pkgs.brightnessctl;
  playerctl = lib.getExe pkgs.playerctl;
  wpctl = lib.getExe' pkgs.wireplumber "wpctl";
  systemctl = lib.getExe' pkgs.systemd "systemctl";
  screenshotDirectory = "${config.home.homeDirectory}/Pictures/Screenshots";
in {
  wayland.windowManager.hyprland = {
    enable = true;
    configType = "lua";

    settings = {
      monitor = [
        {
          output = "LVDS-2";
          mode = "1440x900@59.90";
          position = "0x0";
          scale = 1;
        }
        {
          output = "LVDS-1";
          disabled = true;
        }
      ];

      gesture = [
        {
          fingers = 3;
          direction = "horizontal";
          action = "workspace";
        }
        {
          fingers = 4;
          direction = "horizontal";
          action = "workspace";
        }
      ];

      config.input = {
        kb_layout = "pl";

        touchpad = {
          natural_scroll = true;
          clickfinger_behavior = true;
          tap_and_drag = false;
        };
      };

      # Avoid cursor-plane flicker on the Intel i915 + nouveau MacBook display.
      config.cursor.no_hardware_cursors = true;
    };

    extraConfig = ''
      require("functions")
    '';
  };

  xdg.configFile."hypr/functions.lua".source = ./hyprland.lua;

  xdg.configFile."hypr/nix-paths.lua".text = ''
    return {
      wofi = "${wofi}",
      hyprlock = "${hyprlock}",
      cliphist = "${cliphist}",
      wl_paste = "${wlPaste}",
      wl_copy = "${wlCopy}",
      wayshot = "${wayshot}",
      hyprshutdown = "${hyprshutdown}",
      kitty = "${kitty}",
      dolphin = "${dolphin}",
      brightnessctl = "${brightnessctl}",
      playerctl = "${playerctl}",
      wpctl = "${wpctl}",
      systemctl = "${systemctl}",
      screenshot_directory = "${screenshotDirectory}",
    }
  '';

  # Ensures Wayshot's output directory exists without imperative setup.
  home.file."Pictures/Screenshots/.keep".text = "";
}
