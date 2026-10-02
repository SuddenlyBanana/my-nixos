{ ... }:

{
  imports = [
    ./networking.nix
    ./storage.nix
    ./wapmail.nix
    ./postgresql
    ./openbao
    ./rke2
  ];

  hadal.microvms = {
    postgresql.enable = true;
    openbao.enable = true;
    rke2.enable = true;
  };
}
