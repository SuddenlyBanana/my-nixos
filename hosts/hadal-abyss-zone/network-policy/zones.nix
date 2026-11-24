{ secrets }:

{
  internal = {
    prefix = "fd00:23ff:8e75::/48";
    services = "fd00:23ff:8e75:7::/64";
    nasAddress = "fd00:23ff:8e75:7::10";
    backupHost = "fd00:23ff:8e75:7::11";
  };

  # OPNsense terminates remote access. This is not a Hadal WireGuard peer.
  remoteAccess.prefix = "${secrets.privateIps.prefixes.homelabUla}:ffff::/64";
}
