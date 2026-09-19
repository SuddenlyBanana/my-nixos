{ nix-flatpak, pkgs, pkgs-unstable, ... }:

{
  imports = [
    nix-flatpak.homeManagerModules.nix-flatpak

    ./fish
    ./zoxide
    ./nnn
    ./btop
    ./fastfetch
    ./nix-your-shell
    ./starship

    ./git
    ./codex

    ./neovim
    ./helix
    ./kate
    ./vscodium

    ./kitty
    ./zen
    ./mpv
    ./vesktop
    ./sober
    ./bottles
  ];

  home.packages = with pkgs; [
    # Shell tools
    which
    tree
    file
    unzip
    wget
    ripgrep
    jq

    # System utils
    pciutils
    usbutils
    strace
    ltrace
    lsof
    iotop
    iftop
    nvtopPackages.full
    intel-gpu-tools

    # Network tools
    dig

    qemu
    python3
    openocd

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
    peazip
    unrar
  ];
}
