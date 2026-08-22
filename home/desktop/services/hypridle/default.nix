{ lib, pkgs, ... }:

let
  hyprlock = lib.getExe pkgs.hyprlock;
  hyprctl = lib.getExe' pkgs.hyprland "hyprctl";
  pgrep = lib.getExe' pkgs.procps "pgrep";
  systemctl = lib.getExe' pkgs.systemd "systemctl";
in
{
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
}
