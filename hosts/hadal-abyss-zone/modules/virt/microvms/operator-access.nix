{ ... }:

{
  users.users.workspace = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIijmUFfAZbhbcFMnWSFyM0NEUviWiVEvCO1qB/jra+/ SuddenlyBanana@proton.me"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      AllowUsers = [ "workspace" ];
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };
}
