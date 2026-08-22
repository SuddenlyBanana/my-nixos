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

  wayland.windowManager.hyprland.settings.env = [
    {
      _args = [ "XCURSOR_THEME" "mikucursor" ];
    }
    {
      _args = [ "XCURSOR_SIZE" "32" ];
    }
  ];
}
