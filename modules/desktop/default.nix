{ ... }:

{
  imports = [ ../. ];

  networking = {
    nftables.enable = true;
    networkmanager = {
      enable = true;
      wifi.backend = "iwd";
    };
    # ok
    wireless.iwd.enable = true;
  };

  services = {
    # The NixOS firewall module translates allowed ports into firewalld zones.
    firewalld = {
      enable = true;
      settings.FirewallBackend = "nftables";
    };

    # Resolved owns hostname DNS and mDNS.  Avahi remains available only for
    # DNS-SD browsing (printers, Chromecast, etc.) and does not publish a second
    # responder for this host's .local name.
    avahi = {
      enable = true;
      nssmdns4 = false;
      nssmdns6 = false;
      openFirewall = true;
      publish.enable = false;
    };
    resolved = {
      enable = true;
      settings.Resolve.MulticastDNS = true;
    };
    flatpak.enable = true;

    usbmuxd.enable = true;
  };
}
