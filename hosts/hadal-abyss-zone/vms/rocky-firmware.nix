{ ... }:

let
  connectx2Hostdevs = [{
    managed = true;
    rom.bar = "off";
    subsys_pci.source.address = {
      domain = 0;
      bus = 1;
      slot = 0;
      function = 0;
    };
  }];

  connectx4Hostdevs = [
    {
      managed = true;
      rom.bar = "off";
      subsys_pci.source.address = {
        domain = 0;
        bus = 3;
        slot = 0;
        function = 0;
      };
    }
    {
      managed = true;
      rom.bar = "off";
      subsys_pci.source.address = {
        domain = 0;
        bus = 3;
        slot = 0;
        function = 1;
      };
    }
  ];

  gib = n: n * 1024 * 1024 * 1024;
in {
  terraform.required_providers.libvirt = {
    source = "dmacvicar/libvirt";
    version = "~> 0.9.8";
  };

  provider.libvirt.uri = "qemu+ssh://workspace@hadal-abyss-zone.local/system";

  variable.nic_set = {
    type = "string";
    default = "connectx4";
    description = "NICs assigned to the maintenance VM: connectx4 or connectx2";
    validation = {
      condition = "\${contains([\"connectx4\", \"connectx2\"], var.nic_set)}";
      error_message = "nic_set must be either connectx4 or connectx2.";
    };
  };

  variable.rocky_iso_path = {
    type = "string";
    default = "/var/lib/libvirt/images/Rocky-8.10-x86_64-dvd1.iso";
    description = "Absolute path to the Rocky Linux 8 installer ISO on the libvirt host";
  };

  locals = {
    inherit connectx2Hostdevs connectx4Hostdevs;
  };

  resource.libvirt_pool.rocky_firmware = {
    name = "rocky-firmware";
    type = "dir";
    target.path = "/var/lib/libvirt/images/rocky-firmware";
  };

  resource.libvirt_volume.rocky_firmware_root = {
    name = "rocky-firmware.qcow2";
    pool = "\${libvirt_pool.rocky_firmware.name}";
    capacity = gib 24;
    target.format.type = "qcow2";
  };

  resource.libvirt_domain.rocky_firmware = {
    name = "rocky-firmware";
    type = "kvm";
    memory = 4096;
    memory_unit = "MiB";
    vcpu = 4;
    running = false;
    autostart = false;

    cpu.mode = "host-passthrough";

    features = {
      acpi = true;
      apic = { };
    };

    os = {
      type = "hvm";
      type_arch = "x86_64";
      type_machine = "q35";
      boot_devices = [ { dev = "hd"; } { dev = "cdrom"; } ];
    };

    devices = {
      disks = [
        {
          device = "disk";
          source.file.file = "\${libvirt_volume.rocky_firmware_root.id}";
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
          source.file.file = "\${var.rocky_iso_path}";
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

      hostdevs = "\${var.nic_set == \"connectx2\" ? local.connectx2Hostdevs : local.connectx4Hostdevs}";

      graphics = [{
        vnc.listen = "127.0.0.1";
      }];
    };
  };
}
