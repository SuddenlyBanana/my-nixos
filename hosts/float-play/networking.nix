{ ... }:

{
  systemd.network.networks."10-wan" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "yes";
    networkConfig.IPv6AcceptRA = true;
  };
}
