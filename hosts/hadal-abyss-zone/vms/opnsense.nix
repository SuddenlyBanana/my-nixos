{ ... }:

let
  # PCI address of the ConnectX-4 Lx SFP28 NIC ports on hadal-abyss-zone
  # (02:00.0 and 02:00.1). Both ports share domain/bus/slot; the two
  # functions are passed through as separate hostdevs below.
  nicAddress = {
    domain = 0;
    bus = 2;
    slot = 0;
  };

  # Current OpnSense release ISO. Bump when a new version is out.
  opnsenseIsoUrl =
    "https://mirror.ams1.nl.leaseweb.net/opnsense/releases/25.7/OPNsense-25.7-dvd-amd64.iso.bz2";

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

  resource.libvirt_volume = {
    opnsense_installer = {
      name = "opnsense-installer.iso";
      pool = "\${libvirt_pool.images.name}";
      target.format.type = "raw";
      create.content.url = opnsenseIsoUrl;
    };

    opnsense_root = {
      name = "opnsense.qcow2";
      pool = "\${libvirt_pool.images.name}";
      capacity = gib 32;
      target.format.type = "qcow2";
    };
  };

  resource.libvirt_domain.opnsense = {
    name = "opnsense";
    type = "kvm";
    memory = 4096;
    memory_unit = "MiB";
    vcpu = 4;

    cpu.mode = "host-passthrough";

    os = {
      type = "hvm";
      type_arch = "x86_64";
      type_machine = "q35";
      boot_devices = [ { dev = "hd"; } { dev = "cdrom"; } ];
    };

    # libvirt's `firmware = "efi"` auto-selection needs firmware descriptor
    # JSONs that nixpkgs doesn't ship. Point at the stable /etc/ovmf paths
    # exposed by hosts/hadal-abyss-zone/modules/virt/vm/default.nix instead.
    loader = {
      readonly = true;
      type = "pflash";
      file = "/etc/ovmf/OVMF_CODE.fd";
    };
    nvram = {
      file = "/var/lib/libvirt/qemu/nvram/opnsense_VARS.fd";
      template = "/etc/ovmf/OVMF_VARS.fd";
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
          source.file.file = "\${libvirt_volume.opnsense_installer.id}";
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

      hostdevs = [
        {
          managed = true;
          subsys_pci.source.address = nicAddress // { function = 0; };
        }
        {
          managed = true;
          subsys_pci.source.address = nicAddress // { function = 1; };
        }
      ];

      graphics = [{
        type = "vnc";
        listen = [{
          type = "address";
          address = "127.0.0.1";
        }];
      }];
    };
  };
}
