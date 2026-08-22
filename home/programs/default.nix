{ pkgs, pkgs-unstable, ... }:

{
  imports = [ ./neovim ./kitty ./git ./helix ./starship ./zen ./codex ./fish ./zoxide ./nnn ./btop ./fastfetch ./nix-your-shell ./kate ];

  home.packages = with pkgs; [
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
}
