{ lib, pkgs, ... }:

let
  # PCI vendor:device IDs
  vfioPciIds = [ "15b3:1015" "15b3:6750" ];
in {
  environment.systemPackages = [ pkgs.sbctl ];

  console.earlySetup = true;

  boot = {
    loader.efi.canTouchEfiVariables = true;

    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };

    kernel.sysctl = {
      "net.ipv6.conf.br-lan.accept_ra" = 2;
      "net.ipv6.conf.br-lan.autoconf" = 1;
    };

    initrd = {
      systemd.enable = true;
      luks.devices.cryptroot.crypttabExtraOpts = [ "tpm2-device=auto" ];
      availableKernelModules =
        [ "xhci_pci" "nvme" "usb_storage" "usbhid" "sd_mod" ];
    };

    kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

    kernelModules =
      [ "kvm-intel" "kvm-amd" "vfio_pci" "vfio_iommu_type1" "vfio" ];

    # Belongs to the Mellanox NICs passed through to opnsense. Loading either
    # driver on the host risks racing vfio-pci and leaves the card in a
    # half-initialized state that survives warm reboots.
    blacklistedKernelModules = [ "mlx4_core" "mlx4_en" "mlx5_core" "mlx5_ib" ];

    # Some ConnectX-4 revisions never wake cleanly from PCI D3; disable it
    # so guests don't hang on `mlx5_core waiting for FW init`.
    extraModprobeConfig = ''
      options vfio-pci disable_idle_d3=1
    '';

    kernelParams = [ "intel_iommu=on" "amd_iommu=on" "iommu=pt" ]
      ++ lib.optional (vfioPciIds != [ ])
      ("vfio-pci.ids=" + lib.concatStringsSep "," vfioPciIds);
  };
}
