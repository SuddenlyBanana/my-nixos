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
