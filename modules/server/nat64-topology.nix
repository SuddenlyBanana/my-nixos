{ secrets }:

let
  ula = secrets.privateIps.prefixes.homelabUla;
in
{
  prefix = "64:ff9b::/96";
  mtu = 1280;
  clientPrefixes = [
    "${secrets.privateIps.hadal-abyss-zone.wg-tunnel.v6}/128"
    secrets.privateIps.subnets.homelabLan
    secrets.privateIps.hadal-abyss-zone.subnets.serviceLan
    "${ula}:300::/56"
  ];
}
