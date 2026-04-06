{ ... }:

{
  nixpkgs.hostPlatform = "x86_64-linux";

  hardware.enableRedistributableFirmware = true;

  networking.enableB43Firmware = true;

  services.libinput.enable = true;
}
