{ ... }:

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
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };
}

