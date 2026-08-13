{ pkgs, lib, secrets, ... }:

let
  mkZone = name: z: {
    inherit (z) domain;
    file = toString (pkgs.writeText "${name}.zone" z.body);
  };
in {
  services.knot = {
    enable = true;
    settings = {
      server.listen = [ "::1@5353" ];

      log = [{
        target = "syslog";
        any = "info";
      }];

      zone = lib.mapAttrsToList mkZone secrets.zones.hadal-abyss-zone;
    };
  };

  services.unbound = {
    enable = true;
    settings = {
      server = {
        interface = [ "::1" secrets.privateIps.hadal-abyss-zone.v6 ];
        access-control = [ "::1 allow" "${secrets.privateIps.prefix.homelabUla} allow" ];
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
