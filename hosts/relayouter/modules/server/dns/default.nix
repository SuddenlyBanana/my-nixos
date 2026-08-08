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
        "${secrets.publicIps.relayouter.v4}@53"
        "${secrets.publicIps.relayouter.v6}@53"
      ];

      log = [{
        target = "syslog";
        any = "info";
      }];

      zone = lib.mapAttrsToList mkZone secrets.zones.relayouter;
    };
  };

  networking.firewall = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
}
