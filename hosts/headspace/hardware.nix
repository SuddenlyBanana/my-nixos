{ modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  hardware.enableRedistributableFirmware = true;

  networking.enableB43Firmware = true;

  services.libinput.enable = true;
}
