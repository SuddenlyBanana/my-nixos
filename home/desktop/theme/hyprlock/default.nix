{ ... }:

{
  programs.hyprlock.settings = {
    background = [{
      monitor = "";
      path = "~/Pictures/paper/Michaelsoft_binbows.png";
      blur_passes = 2;
      blur_size = 6;
      noise = 0.015;
      contrast = 0.9;
      brightness = 0.7;
    }];

    input-field = [{
      monitor =  "";
      size = "320, 54";
      outline_thickness = 2;
      dots_size = 0.22;
      dots_spacing = 0.18;
      dots_center = true;

      outer_color = "rgb(c6a0f6)";
      inner_color = "rgb(24273a)";
      font_color = "rgb(cad3f5)";
      placeholder_text = "<i>Password…</i>";
      fail_color = "rgb(ed8796)";
      fail_text = "<i>$FAIL <b>($ATTEMPTS)</b></i>";

      position = "0, -60";
      halign = "center";
      valign = "center";
    }];

    label = [
      {
        monitor = "";
        text = ''cmd[update:1000] echo "$(date '+%H:%M')"'';
        color = "rgb(cad3f5)";
        font_size = 72;
        font_family = "JetBrainsMono Nerd Font";
        position = "0, 80";
        halign = "center";
        valign = "center";
      }
      {
        monitor = "";
        text = ''cmd[update:1000] echo "$(date '+%A, %d %B')"'';
        color = "rgb(a5adcb)";
        font_size = 16;
        font_family = "JetBrainsMono Nerd Font";
        position = "0, 25";
        halign = "center";
        valign = "center";
      }
    ];
  };
}
