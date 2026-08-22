{ ... }:

{
  imports = [ ./desktop ./programs ];

  home = {
    username = "niko";
    homeDirectory = "/home/niko";
    stateVersion = "25.11";
  };

  services.ssh-agent.enable = true;
}
