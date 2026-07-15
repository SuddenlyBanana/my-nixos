{ modulesPath, lib, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disko.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules =
    [ "ata_piix" "uhci_hcd" "xhci_pci" "virtio_pci" "virtio_scsi" "sr_mod" "virtio_blk" ];

  # Vultr provides IPv4 via DHCP and IPv6 via SLAAC on the primary NIC.
  # NetworkManager is overkill on a headless VPS; use networkd instead.
  networking.networkmanager.enable = lib.mkForce false;
  networking.useNetworkd = true;
  systemd.network.networks."10-wan" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "yes";
    networkConfig.IPv6AcceptRA = true;
  };

  # Needed for the initial nixos-anywhere run — colmena takes over via the
  # workspace user afterwards.
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "prohibit-password";
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIijmUFfAZbhbcFMnWSFyM0NEUviWiVEvCO1qB/jra+/ SuddenlyBanana@proton.me"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKPQ80PQ7ZhPmQm9PJ4DLebxsVX8WvChA61twLuzYbH3 teto"
  ];
}
