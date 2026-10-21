{ ... }:

{
  networking.useDHCP = false;
  systemd.network.networks."10-lan" = {
    matchConfig.Name = "end0 eth0 en*";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
      MulticastDNS = true;
    };
    linkConfig.RequiredForOnline = "routable";
  };
}
