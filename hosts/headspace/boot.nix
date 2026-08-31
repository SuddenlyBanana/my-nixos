{ lib, pkgs, ... }:

let
  preferIntegratedGpu = pkgs.writeShellApplication {
    name = "prefer-integrated-gpu";
    runtimeInputs = with pkgs; [ e2fsprogs ];
    text = builtins.readFile ./prefer-integrated-gpu.sh;
  };
in
{
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    initrd = {
      # vga_switcheroo is built into the kernel. Load the Apple gMux handler
      # before either GPU registers so it can provide the display mux.
      kernelModules = [ "apple_gmux" ];
      luks.devices.cryptroot = {
        device = "/dev/disk/by-partuuid/67cc14f5-22fd-44dc-8cfd-78091902bf39";
        allowDiscards = true;
      };
      availableKernelModules = [
        "xhci_pci"
        "ehci_pci"
        "ahci"
        "firewire_ohci"
        "usbhid"
        "usb_storage"
        "sd_mod"
        "sr_mod"
        "sdhci_pci"
      ];
    };
    kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
    kernelModules = [
      "i915"
      "nouveau"
      "kvm-intel"
      "b43"
      "vfio-pci"
    ];
    kernelParams = [ "intel_iommu=on" ];
    extraModprobeConfig = ''
      options vfio_iommu_type1 allow_unsafe_interrupts=1
    '';
    consoleLogLevel = 3;
  };

  # Apple firmware reads this EFI variable before Linux starts. It selects the
  # Intel GPU as the panel owner, allowing i915 to initialize LVDS-1 at boot.
  system.activationScripts.preferIntegratedGpu.text = "${preferIntegratedGpu}/bin/prefer-integrated-gpu";
}
