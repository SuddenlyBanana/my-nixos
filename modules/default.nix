{ ... }:

{
  networking.networkmanager.enable = true;

  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  programs.fish.enable = true;

  security.sudo.wheelNeedsPassword = false;

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

