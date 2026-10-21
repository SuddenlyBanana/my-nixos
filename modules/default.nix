{ pkgs, ... }:

let
  # Terminfo is architecture-independent data. Taking kitty.terminfo would
  # build the full terminal, including its graphics tools, even on servers.
  kittyTerminfo =
    pkgs.pkgsBuildBuild.runCommand "kitty-terminfo-${pkgs.kitty.version}"
      {
        nativeBuildInputs = [ pkgs.pkgsBuildBuild.ncurses ];
      }
      ''
        mkdir -p "$out/share/terminfo"
        tic -x -o "$out/share/terminfo" "${pkgs.kitty.src}/terminfo/kitty.terminfo"
      '';
in
{
  boot.loader = {
    systemd-boot.configurationLimit = 10;
    grub.configurationLimit = 10;
  };

  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  programs = {
    fish.enable = true;
    neovim = {
      enable = true;
      defaultEditor = true;
    };
  };

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  environment.systemPackages = [ kittyTerminfo ];
}
