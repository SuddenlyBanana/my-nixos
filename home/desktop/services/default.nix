{ ... }:

{
  imports = [ ./gammastep ./hypridle ./hyprpaper ./swaync ./kanshi ];

  services = {
    hyprpolkitagent.enable = true;
    udiskie.enable = true;
  };
}
