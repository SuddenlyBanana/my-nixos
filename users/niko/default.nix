{ pkgs, ... }:

{
  users.users.niko = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIijmUFfAZbhbcFMnWSFyM0NEUviWiVEvCO1qB/jra+/ SuddenlyBanana@proton.me"
    ];
  };

  home-manager.users.niko = import ../../home;
}
