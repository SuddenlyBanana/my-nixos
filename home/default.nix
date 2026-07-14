{ pkgs, ... }:

{
  imports = [ ./hyprland ./kitty ./git ./helix ./starship ];

  home = {
    username = "niko";
    homeDirectory = "/home/niko";
    stateVersion = "25.11";
    packages = with pkgs; [
      # Shell tools
      fastfetch
      btop
      nnn
      which
      tree
      file

      # System utils
      wget
      pciutils
      usbutils
      strace
      ltrace
      lsof
      iotop
      iftop

      gptfdisk
      wimlib

      nix-output-monitor
    ];
  };

  services.ssh-agent.enable = true;
}
