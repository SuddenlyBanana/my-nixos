{ nix-flatpak, pkgs, pkgs-unstable, ... }:

{
  imports = [
    nix-flatpak.homeManagerModules.nix-flatpak

    ./neovim
    ./kitty
    ./git
    ./helix
    ./starship
    ./zen
    ./codex
    ./fish
    ./zoxide
    ./nnn
    ./btop
    ./fastfetch
    ./nix-your-shell
    ./kate
    ./mpv
    ./vesktop
    ./sober
  ];

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
    nvtopPackages.full
    intel-gpu-tools

    qemu
    python3

    gptfdisk
    wimlib
    dmg2img

    winbox
    pkgs-unstable.signal-desktop
    (pkgs-unstable.kicad.override {
      addons = with pkgs-unstable.kicadAddons; [
        kikit
        kikit-library
      ];
    })
    pkgs-unstable.kikit
    libreoffice
    onlyoffice-desktopeditors
    darktable
    (heroic.override {
      extraPkgs = pkgs': with pkgs'; [
        gamemode
        gamescope
      ];
    })
  ];
}
