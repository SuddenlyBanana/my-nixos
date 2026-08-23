{ ... }:

{
  imports = [ ./hyprland ./hyprlock ./gtk ./qt ];

  programs = {
    waybar.style = builtins.readFile ./waybar.css;
    wofi.style = builtins.readFile ./wofi.css;
  };
  services.swaync.style = builtins.readFile ./swaync.css;
}
