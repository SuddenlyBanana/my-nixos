{ ... }:

{
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
}
