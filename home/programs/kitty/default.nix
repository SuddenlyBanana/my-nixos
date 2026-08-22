{ ... }:

{
  programs.kitty = {
    enable = true;
    shellIntegration.enableFishIntegration = true;
    themeFile = "Catppuccin-Mocha";
    settings = {
      font_family = "JetBrainsMono Nerd Font Mono";

      # Lets nnn's preview-tui open an unfocused preview split and use Kitty's
      # graphics protocol for image and video previews.
      allow_remote_control = "yes";
      listen_on = "unix:/tmp/kitty";
      enabled_layouts = "splits,*";
    };
  };
}
