{ pkgs, pkgs-unstable, ... }:

{
  imports = [ ./neovim ./kitty ./git ./helix ./starship ./zen ./codex ./fish ./zoxide ./nnn ./btop ./fastfetch ./nix-your-shell ./kate ./mpv ];

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
    pkgs-unstable.signal-desktop
    (pkgs-unstable.kicad.override {
      addons = with pkgs-unstable.kicadAddons; [ kikit kikit-library ];
    })
    pkgs-unstable.kikit
    libreoffice
    onlyoffice-desktopeditors
    darktable
  ];
}
