{ secrets }:

let
  ula = secrets.privateIps.prefixes.homelabUla;
in
{
  service = {
    prefix = secrets.privateIps.hadal-abyss-zone.subnets.serviceLan;
    hostAddress = "${ula}:9::1";
    rke2Address = "${ula}:9::20";
  };

  infrastructure = {
    prefix = "${ula}:200::/64";
    hostAddress = "${ula}:200::1";
    postgresqlAddress = "${ula}:200::10";
    openbaoAddress = "${ula}:200::21";
  };

  cluster = {
    podCidr = "${ula}:300::/56";
    serviceCidr = "${ula}:400::/112";
    dnsAddress = "${ula}:400::a";
    ingressHttpNodePort = 30080;
  };
}
