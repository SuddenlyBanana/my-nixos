{ pkgs, ... }:

{
  users.users.workspace = {
    isNormalUser = true;
    extraGroups = [ "wheel" "libvirtd" "kvm" ];
    shell = pkgs.fish;

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIijmUFfAZbhbcFMnWSFyM0NEUviWiVEvCO1qB/jra+/ SuddenlyBanana@proton.me"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKPQ80PQ7ZhPmQm9PJ4DLebxsVX8WvChA61twLuzYbH3 teto"
    ];
  };
}
