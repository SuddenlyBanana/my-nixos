{ modulesPath, pkgs, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  hardware.enableRedistributableFirmware = true;

  networking.enableB43Firmware = true;

  services.libinput.enable = true;

  # Apple SMC exposes the keyboard backlight as an LED, but its brightness
  # attribute is root-writable by default. Delegate only this LED to `video`.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="leds", KERNEL=="smc::kbd_backlight", \
      RUN+="${pkgs.coreutils}/bin/chgrp video /sys/class/leds/%k/brightness", \
      RUN+="${pkgs.coreutils}/bin/chmod g+w /sys/class/leds/%k/brightness"
  '';
}
