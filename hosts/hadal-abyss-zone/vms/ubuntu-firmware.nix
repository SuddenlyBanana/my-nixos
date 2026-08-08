{ ... }:

let
  # Host address 01:00.0 (15b3:6750): ConnectX-2 EN.
  # Do not attach it to OPNsense while this maintenance VM is running.
  connectx2Hostdev = {
    managed = true;
    rom.bar = "off";
    subsys_pci.source.address = {
      domain = 0;
      bus = 2;
      slot = 0;
      function = 0;
    };
  };

  gib = n: n * 1024 * 1024 * 1024;
in {
  terraform.required_providers.libvirt = {
    source = "dmacvicar/libvirt";
    version = "~> 0.9.8";
  };

  provider.libvirt.uri = "qemu+ssh://workspace@hadal-abyss-zone.local/system";

  variable.ubuntu_iso_path = {
    type = "string";
    default = "/var/lib/libvirt/images/ubuntu-14.04.4-server-amd64.iso";
    description =
      "Absolute path to the Ubuntu 14.04.4 Server amd64 ISO on the libvirt host";
  };

  resource.libvirt_pool.ubuntu_firmware = {
    name = "ubuntu-firmware";
    type = "dir";
    target.path = "/var/lib/libvirt/images/ubuntu-firmware";
  };

  resource.libvirt_volume.ubuntu_firmware_root = {
    name = "ubuntu-firmware.qcow2";
    pool = "\${libvirt_pool.ubuntu_firmware.name}";
    capacity = gib 20;
    target.format.type = "qcow2";
  };

  resource.libvirt_domain.ubuntu_firmware = {
    name = "ubuntu-firmware";
    type = "kvm";
    memory = 2048;
    memory_unit = "MiB";
    vcpu = 2;
    running = false;
    autostart = false;

    cpu.mode = "host-passthrough";

    features = {
      acpi = true;
      apic = { };
    };

    # Deliberately use SeaBIOS: this avoids the OVMF page-alignment hang seen
    # with the Rocky maintenance VM, and MFT does not require UEFI.
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
          source.file.file = "\${libvirt_volume.ubuntu_firmware_root.id}";
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
          source.file.file = "\${var.ubuntu_iso_path}";
          target = {
            dev = "sda";
            bus = "sata";
          };
        }
      ];

      # This is optional for the firmware procedure, but permits package/file
      # transfer while the host has its independent USB-tethered uplink.
      interfaces = [{
        model.type = "virtio";
        source.bridge.bridge = "br-lan";
      }];

      hostdevs = [ connectx2Hostdev ];

      graphics = [{ vnc.listen = "127.0.0.1"; }];
    };
  };
}
