{ modulesPath, ... }:

{
  imports = [ (modulesPath + "/virtualisation/digital-ocean-config.nix") ];

  virtualisation.digitalOcean = {
    setSshKeys = true;
    setRootPassword = false;
  };
}
