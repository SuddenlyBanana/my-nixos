{ pkgs, lib, ... }:

let
  lanIp = "10.10.0.2";
  lanIp6 = "fd10:10:0::2";
  gwIp6 = "fd10:10:0::1";
  vpsTunnelIp = "10.99.0.1";

  homeArpaZone = pkgs.writeText "home.arpa.zone" ''
    $ORIGIN home.arpa.
    $TTL 3600
    @ IN SOA ns1.home.arpa. hostmaster.home.arpa. (
      1 3600 900 604800 300 )
    @                IN NS   ns1.home.arpa.
    @                IN NS   ns2.home.arpa.
    ns1              IN A    ${lanIp}
    ns1              IN AAAA ${lanIp6}
    ns2              IN A    ${vpsTunnelIp}
    opnsense         IN A    10.10.0.1
    opnsense         IN AAAA ${gwIp6}
    hadal-abyss-zone IN A    ${lanIp}
    hadal-abyss-zone IN AAAA ${lanIp6}
  '';
in {
  services.knot = {
    enable = true;
    settings = {
      server.listen = [ "127.0.0.1@5353" ];

      log = [{
        target = "syslog";
        any = "info";
      }];

      acl = [{
        id = "secondary";
        address = [ vpsTunnelIp ];
        action = [ "transfer" ];
      }];

      remote = [{
        id = "secondary";
        address = "${vpsTunnelIp}@53";
      }];

      template = [{
        id = "default";
        notify = [ "secondary" ];
        acl = [ "secondary" ];
      }];

      zone = [{
        domain = "home.arpa";
        file = toString homeArpaZone;
        template = "default";
      }];
    };
  };

  services.unbound = {
    enable = true;
    settings = {
      server = {
        interface = [ "127.0.0.1" "::1" lanIp lanIp6 ];
        access-control = [
          "127.0.0.0/8 allow"
          "10.10.0.0/24 allow"
          "::1 allow"
          "fd10:10:0::/64 allow"
        ];
        hide-identity = "yes";
        hide-version = "yes";

        # DNS64: synthesize AAAA from A into the well-known NAT64 prefix
        # so v6-only clients can reach v4-only destinations via Jool on
        # relayouter (routed through the wg0 tunnel).
        module-config = ''"dns64 validator iterator"'';
        dns64-prefix = "64:ff9b::/96";
      };

      stub-zone = [{
        name = "home.arpa";
        stub-addr = "127.0.0.1@5353";
      }];

      forward-zone = [{
        name = ".";
        forward-addr = [ "1.1.1.1" "9.9.9.9" ];
      }];
    };
  };

  networking.firewall.interfaces.br-lan = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
}
