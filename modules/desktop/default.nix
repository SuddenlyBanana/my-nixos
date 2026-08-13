{ ... }:

{
  imports = [ ../. ];

  networking.networkmanager.enable = true;

  # Resolved owns hostname DNS and mDNS.  Avahi remains available only for
  # DNS-SD browsing (printers, Chromecast, etc.) and does not publish a second
  # responder for this host's .local name.
  services = {
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
  };

  # RouterOS Winbox neighbor discovery.
  networking.firewall.allowedUDPPorts = [ 5678 ];
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p udp --sport 20561 --dport 10000:65535 \
      -s 0.0.0.0 -d 255.255.255.255 -j nixos-fw-accept
  '';
}
