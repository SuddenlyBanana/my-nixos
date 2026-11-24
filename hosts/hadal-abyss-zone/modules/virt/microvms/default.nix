{ ... }:

{
  imports = [
    ./bootstrap.nix
    ./backups
    ./storage-format.nix
    ./networking.nix
    ./storage.nix
    ./postgresql
    ./openbao
    ./rke2
  ];

  hadal.microvms = {
    postgresql = {
      enable = true;
      autostart = true;
    };
    openbao = {
      enable = true;
      autostart = true;
    };
    rke2 = {
      enable = true;
      autostart = true;
    };
  };
}
