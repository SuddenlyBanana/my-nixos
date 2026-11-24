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
    # Native-routed local bridge/TAP/guest/pod path; Internet and WireGuard
    # paths retain their smaller MTUs and rely on IPv6 path MTU discovery.
    mtu = 9000;
    podCidr = "${ula}:300::/56";
    serviceCidr = "${ula}:400::/112";
    dnsAddress = "${ula}:400::a";
    ingressHttpNodePort = 30080;
  };
}
