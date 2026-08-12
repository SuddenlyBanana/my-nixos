{ ... }:

{
  imports = [ ../. ];

  networking.networkmanager.enable = true;
  # RouterOS Winbox neighbor discovery.
  networking.firewall.allowedUDPPorts = [ 5678 ];
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p udp --sport 20561 --dport 10000:65535 \
      -s 0.0.0.0 -d 255.255.255.255 -j nixos-fw-accept
  '';
}
