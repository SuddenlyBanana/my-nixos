{
  pkgs,
  lib,
  secrets,
  ...
}:

let
  nat64 = import ../../../../../modules/server/nat64-topology.nix { inherit secrets; };
  mkZone = name: z: {
    domain = z.domain or z.name;
    file = toString (pkgs.writeText "${name}.zone" z.body);
  };
in
{
  services.knot = {
    enable = true;
    settings = {
      server.listen = [ "::1@5353" ];

      log = [
        {
          target = "syslog";
          any = "info";
        }
      ];

      zone = lib.mapAttrsToList mkZone secrets.zones.hadal-abyss-zone;
    };
  };

  services.unbound = {
    enable = true;
    checkconf = true;
    settings = {
      server = {
        module-config = "\"dns64 validator iterator\"";
        do-not-query-localhost = false;
        dns64-prefix = nat64.prefix;
        interface = [
          "::1"
          secrets.privateIps.hadal-abyss-zone.static.v6
        ];
        access-control = [
          "::1 allow"
          "${secrets.privateIps.subnets.homelabLan} allow"
          "${secrets.privateIps.float-play.v6} allow"
        ];
        hide-identity = "yes";
        hide-version = "yes";
      };

      stub-zone = [
        {
          name = "infra.windows.moe";
          stub-addr = "::1@5353";
        }
      ];

      forward-zone = [
        {
          name = ".";
          forward-addr = [
            "2606:4700:4700::1111"
            "2620:fe::fe"
          ];
        }
      ];
    };
  };

  networking.firewall.interfaces.br-lan = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
}
