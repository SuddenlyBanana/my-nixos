{ config, pkgs, ... }:

let
  wallpaperSlideshow = pkgs.writeShellApplication {
    name = "awww-wallpaper-slideshow";
    runtimeInputs = with pkgs; [ awww coreutils findutils ];
    text = builtins.readFile ./wallpaper-slideshow.sh;
  };
in
{
  services.awww.enable = true;

  systemd.user.services.awww-wallpaper-slideshow = {
    Unit = {
      Description = "Random wallpaper slideshow";
      After = [ config.wayland.systemd.target ];
    };
    Service = {
      ExecStart = "${wallpaperSlideshow}/bin/awww-wallpaper-slideshow";
      Restart = "always";
      RestartSec = 5;
    };
    Install.WantedBy = [ config.wayland.systemd.target ];
  };
}
