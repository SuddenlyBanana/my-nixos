{ ... }:

{
  imports = [ ./gammastep ./hypridle ./awww ./swaync ./kanshi ];

  services = {
    hyprpolkitagent.enable = true;
    udiskie.enable = true;
  };
}
