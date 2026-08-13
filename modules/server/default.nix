{ ... }:

{
  imports = [ ../. ];

  networking.useNetworkd = true;
  networking.firewall.allowedUDPPorts = [ 5353 ];
  security.sudo.wheelNeedsPassword = false;

  # Servers use resolved as their sole mDNS responder.  Do not enable Avahi
  # here as running both responders causes .local hostname conflicts.
  services.resolved = {
    enable = true;
    settings.Resolve.MulticastDNS = true;
  };
}
