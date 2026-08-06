{ ... }:

{
  imports = [ ../. ];

  networking.useNetworkd = true;
  security.sudo.wheelNeedsPassword = false;
}
