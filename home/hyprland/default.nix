{ config, hyprqt6engine, lib, pkgs, ... }:

let
  hyprlock = lib.getExe pkgs.hyprlock;
  wofi = lib.getExe pkgs.wofi;
  cliphist = lib.getExe pkgs.cliphist;
  wlPaste = lib.getExe' pkgs.wl-clipboard "wl-paste";
  wlCopy = lib.getExe' pkgs.wl-clipboard "wl-copy";
  wayshot = lib.getExe pkgs.wayshot;
  hyprctl = lib.getExe' pkgs.hyprland "hyprctl";
  hyprshutdown = lib.getExe pkgs.hyprshutdown;
  kitty = lib.getExe pkgs.kitty;
  nnn = lib.getExe pkgs.nnn;
  hyprpwcenter = lib.getExe' pkgs.hyprpwcenter "hyprpwcenter";
  nmConnectionEditor = lib.getExe' pkgs.networkmanagerapplet "nm-connection-editor";
  brightnessctl = lib.getExe pkgs.brightnessctl;
  playerctl = lib.getExe pkgs.playerctl;
  wpctl = lib.getExe' pkgs.wireplumber "wpctl";
  pgrep = lib.getExe' pkgs.procps "pgrep";
  systemctl = lib.getExe' pkgs.systemd "systemctl";
in
{
  imports = [ ./theme.nix ];

  # Home Manager generates the data-only part of the Lua configuration. The
  # bindings and callbacks live in functions.lua and are loaded afterwards.
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
        };
      };

      # Avoid cursor-plane flicker on the Intel i915 + nouveau MacBook display.
      config.cursor.no_hardware_cursors = true;
    };

    extraConfig = ''
      require("functions")
    '';
  };

  wayland.windowManager.hyprland.settings.env = [
    {
      _args = [ "XCURSOR_THEME" "mikucursor" ];
    }
    {
      _args = [ "XCURSOR_SIZE" "32" ];
    }
  ];

  gtk = {
    enable = true;
    font = {
      name = "JetBrainsMono Nerd Font";
      size = 10;
    };
    theme = {
      # KiCad uses wxGTK. Catppuccin's GTK stylesheet leaves some wx widgets
      # light while rendering their text dark, so use a complete GTK 3 theme.
      name = "adw-gtk3-dark";
      package = pkgs.adw-gtk3;
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
      /* wxGTK applications such as KiCad otherwise inherit adw-gtk3's
         deliberately heavy control typography. */
      * { font-weight: normal; }
    '';
  };

  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";

  home.packages = [
    pkgs.hyprlock
    pkgs.cliphist
    pkgs.wl-clipboard
    pkgs.wayshot
    pkgs.brightnessctl
    pkgs.playerctl
    pkgs.hyprpwcenter
    pkgs.hyprshutdown
    pkgs.hyprsysteminfo
    pkgs.hyprland-qt-support
    hyprqt6engine.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  services.udiskie.enable = true;

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "${pgrep} -x hyprlock || ${hyprlock}";
        before_sleep_cmd = "${pgrep} -x hyprlock || ${hyprlock}";
        after_sleep_cmd = "${hyprctl} dispatch dpms on";
      };

      listener = [
        {
          timeout = 300;
          on-timeout = "${pgrep} -x hyprlock || ${hyprlock}";
        }
        {
          timeout = 600;
          on-timeout = "${hyprctl} dispatch dpms off";
          on-resume = "${hyprctl} dispatch dpms on";
        }
        {
          timeout = 1800;
          on-timeout = "${systemctl} suspend";
        }
      ];
    };
  };

  services.hyprpolkitagent.enable = true;

  services.gammastep = {
    enable = true;
    provider = "geoclue2";
    temperature = {
      day = 6500;
      night = 5000;
    };
  };

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
      "modules-right" = [ "pulseaudio" "network" "battery" "clock" "tray" ];
      pulseaudio.on-click = hyprpwcenter;
      network.on-click = nmConnectionEditor;
      clock.format = "{:%a, %d %b  %H:%M}";
      battery.format = "{capacity}% {icon}";
      battery.format-icons = [ "󰂎" "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
    };
  };

  programs.wofi = {
    enable = true;
    settings = {
      width = 600;
      height = 400;
      prompt = "Search";
      insensitive = true;
    };
  };

  services.hyprpaper = {
    enable = true;
    settings = {
      splash = false;

      wallpaper = [{
        monitor = "LVDS-2";
        path = "/home/niko/Pictures/paper";
        fit_mode = "cover";
        timeout = 300;
        order = "random";
      }];
    };
  };

  services.mako = {
    enable = true;
    settings = {
      anchor = "top-right";
      width = 360;
      height = 120;
      margin = 10;
      padding = 12;

      default-timeout = 5000;
      icons = true;
      markup = true;
    };
  };


  # Keep functions and callbacks in an editable module for LuaLS and linters.
  xdg.configFile."hypr/functions.lua".source = ./hyprland.lua;

  # Nix owns only the store-dependent paths used by the Lua configuration.
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
      nnn = "${nnn}",
      brightnessctl = "${brightnessctl}",
      playerctl = "${playerctl}",
      wpctl = "${wpctl}",
      systemctl = "${systemctl}",
    }
  '';
}
