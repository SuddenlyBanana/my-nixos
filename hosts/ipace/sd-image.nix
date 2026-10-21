{ lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/sd-card/sd-image-aarch64.nix") ];

  # The generic image requests drivers for other ARM boards that the Pi
  # vendor kernel does not provide. Keep the defaults and Pi 5 module list.
  hardware.enableAllHardware = lib.mkForce false;

  # nixos-hardware replaces the generic image's Pi 3/4 firmware population.
  sdImage.firmwareSize = 256;
}
