{ pkgs, ... }:

let
  lanIp6 = "fd10:10:0::2";
  gwIp6 = "fd10:10:0::1";

  homeArpaZone = pkgs.writeText "home.arpa.zone" ''
    $ORIGIN home.arpa.
    $TTL 3600
    @ IN SOA ns1.home.arpa. hostmaster.home.arpa. (
      1 3600 900 604800 300 )
    @                IN NS   ns1.home.arpa.
    ns1              IN AAAA ${lanIp6}
    opnsense         IN AAAA ${gwIp6}
    hadal-abyss-zone IN AAAA ${lanIp6}
  '';
in {
  services.knot = {
    enable = true;
    settings = {
      server.listen = [ "::1@5353" ];

      log = [{
        target = "syslog";
        any = "info";
      }];

      zone = [{
        domain = "home.arpa";
        file = toString homeArpaZone;
      }];
    };
  };

  services.unbound = {
    enable = true;
    settings = {
      server = {
        interface = [ "::1" lanIp6 ];
        access-control = [
          "::1 allow"
          "fd10:10:0::/64 allow"
        ];
        hide-identity = "yes";
        hide-version = "yes";
      };

      stub-zone = [{
        name = "home.arpa";
        stub-addr = "::1@5353";
      }];

      forward-zone = [{
        name = ".";
        forward-addr = [ "2606:4700:4700::1111" "2620:fe::fe" ];
      }];
    };
  };

  networking.firewall.interfaces.br-lan = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
}
