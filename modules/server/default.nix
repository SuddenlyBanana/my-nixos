{ ... }:

{
  imports = [ ../. ];

  networking.useNetworkd = true;
  security.sudo.wheelNeedsPassword = false;

  nix.settings.trusted-users = [ "root" "workspace" ];

  # Servers use resolved as their sole mDNS responder.  Do not enable Avahi
  # here as running both responders causes .local hostname conflicts.
  services.resolved = {
    enable = true;
    settings.Resolve.MulticastDNS = true;
  };
}
