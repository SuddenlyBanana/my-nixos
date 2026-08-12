{ pkgs, pkgs-unstable, ... }:

{
  imports = [ ./neovim ./hyprland ./kitty ./git ./helix ./starship ./vscode ./zen ./codex ./fish ./zoxide ./nnn ./btop ./fastfetch ./nix-your-shell ];

  home = {
    username = "niko";
    homeDirectory = "/home/niko";
    stateVersion = "25.11";
    packages = with pkgs; [
      # Shell tools
      which
      tree
      file
      unzip

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
      dmg2img

      winbox
      signal-desktop
      pkgs-unstable.kicad
      kikit
      libreoffice
      onlyoffice-desktopeditors
    ];
  };

  services.ssh-agent.enable = true;
}
