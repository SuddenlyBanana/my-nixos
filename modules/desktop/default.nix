{ ... }:

{
  imports = [ ../. ];

  networking.networkmanager.enable = true;

  # Avahi provides DNS-SD browsing for local printers and other desktop-facing
  # services.  Keep systemd-resolved's mDNS responder disabled to avoid it
  # competing with Avahi for this host's .local name.
  services = {
    avahi = {
      enable = true;
      nssmdns4 = true;
      nssmdns6 = true;
      openFirewall = true;
    };
    resolved.extraConfig = ''
      MulticastDNS=no
    '';
  };

  # RouterOS Winbox neighbor discovery.
  networking.firewall.allowedUDPPorts = [ 5678 ];
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p udp --sport 20561 --dport 10000:65535 \
      -s 0.0.0.0 -d 255.255.255.255 -j nixos-fw-accept
  '';
}
