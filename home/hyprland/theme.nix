{ ... }:

{
  wayland.windowManager.hyprland.settings = {
    config = {
      general = {
        gaps_in = 5;
        gaps_out = 10;
        border_size = 2;
        col = {
          active_border = {
            colors = [ "rgba(8aadf4ff)" "rgba(c6a0f6ff)" ];
            angle = 45;
          };
          inactive_border = "rgba(5b6078aa)";
        };
      };

      decoration = {
        rounding = 10;

        blur = {
          enabled = true;
          size = 6;
          passes = 3;
        };

        shadow = {
          enabled = true;
          range = 12;
          render_power = 3;
          color = "rgba(181926cc)";
        };
      };

      animations.enabled = true;
    };

    animation = [
      { leaf = "windows"; enabled = true; speed = 5; bezier = "default"; }
      { leaf = "workspaces"; enabled = true; speed = 4; bezier = "default"; }
      { leaf = "fade"; enabled = true; speed = 4; bezier = "default"; }
    ];
  };

  services.mako.settings = {
    font = "JetBrainsMono Nerd Font 11";
    background-color = "#24273a";
    text-color = "#cad3f5";
    border-color = "#8aadf4";
    border-size = 2;
    border-radius = 10;

    "urgency=critical" = {
      border-color = "#ed8796";
      default-timeout = 0;
    };
  };


  programs.waybar.style = builtins.readFile ./waybar.css;
  programs.wofi.style = builtins.readFile ./wofi.css;
}
