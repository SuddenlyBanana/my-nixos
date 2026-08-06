{ ... }:

{
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    initrd.availableKernelModules = [
      "ata_piix"
      "uhci_hcd"
      "xhci_pci"
      "virtio_pci"
      "virtio_scsi"
      "sr_mod"
      "virtio_blk"
    ];
  };
}
