{ pkgs, ... }:

{
  imports = [ ../. ];

  services = {
    pipewire = {
      enable = true;
      alsa = {
        enable = true;
        support32Bit = true;
      };

      pulse.enable = true;
    };

    printing.enable = true;
  };

  programs = {
    hyprland.enable = true;
    regreet.enable = true;
  };

  security.rtkit.enable = true;

  environment.systemPackages = with pkgs; [ vulkan-tools mesa-demos ];
}
