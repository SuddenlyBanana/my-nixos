{ ... }:

let
  # PCI address of the ConnectX-2 EN NIC passed through as a single function.
  connectx2Address = {
    domain = 0;
    bus = 2;
    slot = 0;
  };

  # PCI address of the ConnectX-4 Lx SFP28 NIC ports on hadal-abyss-zone
  # (03:00.0 and 03:00.1). Both ports share domain/bus/slot; the two
  # functions are passed through as separate hostdevs below.
  # connectx4Address = {
  #   domain = 0;
  #   bus = 3;
  #   slot = 0;
  # };

  # OpnSense installer ISO. Fetched + decompressed manually on hadal because
  # OpnSense only publishes .iso.bz2 and the libvirt provider does not
  # decompress downloads. See CLAUDE.md / the VM install runbook.
  opnsenseIsoPath = "/var/lib/libvirt/images/opnsense-installer.iso";

  gib = n: n * 1024 * 1024 * 1024;
in {
  terraform.required_providers.libvirt = {
    source = "dmacvicar/libvirt";
    version = "~> 0.9.8";
  };

  provider.libvirt.uri = "qemu+ssh://workspace@hadal-abyss-zone.local/system";

  resource.libvirt_pool.images = {
    name = "images";
    type = "dir";
    target.path = "/var/lib/libvirt/images";
  };

  resource.libvirt_volume.opnsense_root = {
    name = "opnsense.qcow2";
    pool = "\${libvirt_pool.images.name}";
    capacity = gib 32;
    target.format.type = "qcow2";
  };

  resource.libvirt_domain.opnsense = {
    name = "opnsense";
    type = "kvm";
    memory = 4096;
    memory_unit = "MiB";
    vcpu = 4;

    autostart = true;

    cpu.mode = "host-passthrough";

    # UEFI on x86 requires ACPI; APIC is standard for modern guests.
    features = {
      acpi = true;
      apic = { };
    };

    os = {
      type = "hvm";
      type_arch = "x86_64";
      type_machine = "q35";
      boot_devices = [ { dev = "hd"; } { dev = "cdrom"; } ];

      # libvirt's `firmware = "efi"` auto-selection needs firmware descriptor
      # JSONs that nixpkgs doesn't ship. Point at the stable /etc/ovmf paths
      # exposed by hosts/hadal-abyss-zone/modules/virt/vm/default.nix instead.
      loader = "/etc/ovmf/OVMF_CODE.fd";
      loader_type = "pflash";
      loader_readonly = "yes";
      nv_ram = {
        nv_ram = "/var/lib/libvirt/qemu/nvram/opnsense_VARS.fd";
        template = "/etc/ovmf/OVMF_VARS.fd";
      };
    };

    devices = {
      disks = [
        {
          device = "disk";
          source.file.file = "\${libvirt_volume.opnsense_root.id}";
          target = {
            dev = "vda";
            bus = "virtio";
          };
          driver = {
            name = "qemu";
            type = "qcow2";
          };
        }
        {
          device = "cdrom";
          read_only = true;
          source.file.file = opnsenseIsoPath;
          target = {
            dev = "sda";
            bus = "sata";
          };
        }
      ];

      interfaces = [{
        model.type = "virtio";
        source.bridge.bridge = "br-lan";
      }];

      hostdevs = [{
        managed = true;
        subsys_pci.source.address = connectx2Address // { function = 0; };
      }
      # {
      #   managed = true;
      #   subsys_pci.source.address = connectx4Address // { function = 0; };
      # }
      # {
      #   managed = true;
      #   subsys_pci.source.address = connectx4Address // { function = 1; };
      # }
        ];

      graphics = [{ vnc.listen = "127.0.0.1"; }];
    };
  };
}
