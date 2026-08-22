{ ... }:

{
  imports = [ ./hyprland ./hyprlock ./gtk ./qt ];

  programs.waybar.style = builtins.readFile ./waybar.css;
  programs.wofi.style = builtins.readFile ./wofi.css;
}
