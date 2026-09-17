{ pkgs, lib, secrets, ... }:

let
  signedDomain = secrets.zones.float-play.domain1.name;
  mkZone = name: z:
    let domain = z.domain or z.name;
    in {
      inherit domain;
      file = toString (pkgs.writeText "${name}.zone" z.body);
    } // lib.optionalAttrs (domain == signedDomain) {
      "dnssec-signing" = true;
      "dnssec-policy" = "public";
      "zonefile-sync" = -1;
      "zonefile-load" = "difference-no-serial";
      "journal-content" = "all";
    };
in {
  services.knot = {
    enable = true;
    settings = {
      policy = [{
        id = "public";
        algorithm = "ecdsap256sha256";
        "ksk-lifetime" = 0;
      }];

      server.listen = [
        "${secrets.publicIps.float-play.v4}@53"
        "${secrets.publicIps.float-play.v6}@53"
      ];

      log = [{
        target = "syslog";
        any = "info";
      }];

      zone = lib.mapAttrsToList mkZone secrets.zones.float-play;
    };
  };

  networking.firewall = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
}
