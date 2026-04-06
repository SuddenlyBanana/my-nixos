{ ... }:

{
  boot.loader = {
    systemd-boot.configurationLimit = 7;
    grub.configurationLimit = 7;
  };
}
