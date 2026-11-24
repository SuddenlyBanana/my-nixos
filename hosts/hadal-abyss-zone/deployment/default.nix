{ lib, ... }:

{
  # A deliberately selected boot generation, never an automatic disk migration.
  # It leaves storage units available for explicit operator starts, but opens
  # no new media/VM mappings, mounts no media, and starts no application guests.
  specialisation.storage-provisioning.configuration = {
    system.nixos.tags = [ "storage-provisioning" ];
    hadal.storage.automaticActivation = lib.mkForce false;
    hadal.backups.enable = lib.mkForce false;
    hadal.microvms = {
      openbao.autostart = lib.mkForce false;
      postgresql.autostart = lib.mkForce false;
      rke2.autostart = lib.mkForce false;
    };
  };
}
