{ config, pkgs, ... }:

{
  # Pi firmware -> U-Boot -> extlinux -> the Pi 5 vendor kernel.
  boot.loader = {
    grub.enable = false;
    generic-extlinux-compatible.enable = true;
  };

  # The Pi vendor kernel lacks the PC TPM drivers added by systemd's initrd.
  boot.initrd.systemd.tpm2.enable = false;

  hardware.raspberry-pi.firmware = {
    enable = true;
    uboot.enable = true;
    # The packaged firmware's older DTBs cannot bind this kernel's Pi 5
    # pinctrl driver. Let the firmware apply its fixups to matching DTBs.
    package =
      pkgs.buildPackages.runCommand "raspberrypi-firmware-${config.boot.kernelPackages.kernel.version}"
        {
          firmware = pkgs.raspberrypifw;
          kernel = config.boot.kernelPackages.kernel;
        }
        (builtins.readFile ./firmware.sh);
  };
}
