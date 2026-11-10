# Evaluate against the real guest config; this does not boot a VM or touch data.
# Usage is recorded in the adjacent, ignored COMMENT.md.
c:

let
  pg = c.systemd.services.postgresql;
  network = c.systemd.network.networks."20-primary";
  waitOnline = c.systemd.network.wait-online;
  listener = c.services.postgresql.settings.listen_addresses;
  checks = {
    waitsForSuccessfulNetworkd =
      builtins.elem "systemd-networkd-wait-online.service" pg.requires
      && builtins.elem "systemd-networkd-wait-online.service" pg.after;
    pullsInOnlineTarget =
      builtins.elem "network-online.target" pg.wants && builtins.elem "network-online.target" pg.after;
    networkdReadinessEnabled =
      c.networking.useNetworkd && c.systemd.network.enable && waitOnline.enable;
    cannotSkipRequiredInterface = !waitOnline.anyInterface && waitOnline.ignoredInterfaces == [ ];
    requiresRoutableIPv6 =
      network.linkConfig.RequiredForOnline == "routable"
      && network.linkConfig.RequiredFamilyForOnline == "ipv6";
    interfaceNameIndependent =
      network.matchConfig.MACAddress == "02:00:00:02:00:10" && !(network.matchConfig ? Name);
    keepsFixedListener =
      listener != "*" && listener != "::" && builtins.elem "${listener}/64" network.address;
    retainsTlsGate =
      c.services.postgresql.settings.ssl
      && builtins.elem "/var/lib/postgresql/tls/current/server.crt" pg.unitConfig.ConditionPathExists
      && builtins.elem "/var/lib/postgresql/tls/current/server.key" pg.unitConfig.ConditionPathExists
      && c.systemd.targets.postgresql.wantedBy == [ ];
    noTlsActivationOrderingCycle =
      !(builtins.elem "activate-postgresql-tls.service" pg.requires)
      && !(builtins.elem "activate-postgresql-tls.service" pg.after);
    retainsDataMount =
      pg.unitConfig.RequiresMountsFor == [ c.services.postgresql.dataDir ]
      && builtins.any (
        volume:
        volume.mountPoint == "/var/lib/postgresql"
        && !volume.autoCreate
        && volume.direct
        && volume.fsType == "xfs"
      ) c.microvm.volumes;
  };
  failed = builtins.filter (name: !checks.${name}) (builtins.attrNames checks);
in
assert
  builtins.length failed == 0
  || throw "PostgreSQL startup regression: ${builtins.concatStringsSep ", " failed}";
{
  inherit checks;
  system = c.system.build.toplevel.outPath;
  postgresql = {
    inherit (pg) after wants requires;
  };
  network = {
    inherit (network) matchConfig linkConfig address;
  };
}
