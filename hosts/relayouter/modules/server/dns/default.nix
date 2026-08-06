{ pkgs, lib, secrets, ... }:

let
  publicIp4 = secrets.publicIps.relayouter.v4;
  publicIp6 = secrets.publicIps.relayouter.v6;

  mkZone = name: z: {
    inherit (z) domain;
    file = toString (pkgs.writeText "${name}.zone" z.body);
  };
in {
  services.knot = {
    enable = true;
    settings = {
      server.listen = [
        "${publicIp4}@53"
        "${publicIp6}@53"
      ];

      log = [{
        target = "syslog";
        any = "info";
      }];

      zone = lib.mapAttrsToList mkZone secrets.zones;
    };
  };

  networking.firewall = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
}
