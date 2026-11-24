{ lib, ... }:
{
  # Credentials arrive on per-VM read-only virtiofs shares. Service state is
  # always on the separately provisioned, encrypted LVM thin devices.
  systemd.services =
    lib.genAttrs
      (map (name: "microvm@${name}") [
        "openbao"
        "postgresql"
        "rke2"
      ])
      (
        unit:
        let
          name = lib.removePrefix "microvm@" unit;
        in
        {
          requires = [
            "hadal-vm-storage.service"
            "hadal-bootstrap-${name}.service"
          ];
          after = [
            "hadal-vm-storage.service"
            "hadal-bootstrap-${name}.service"
          ];
        }
      );
}
