{ pkgs, ... }:

{
  virtualisation.libvirtd = {
    enable = true;
    onBoot = "ignore";
    onShutdown = "shutdown";
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
    };
  };

  users.users.workspace.extraGroups = [ "libvirtd" "kvm" ];

  environment.systemPackages = with pkgs; [ virt-manager virtiofsd ];

  # Host <-> OpnSense LAN bridge. OpnSense attaches a virtio-net here.
  # Static v4 + ULA v6 so the host stays reachable (and serves DNS)
  # independent of OpnSense DHCP/RA being up. A routable GUA is picked up
  # from OpnSense's RAs on top of these when the ISP hands out a prefix.
  networking = {
    bridges.br-lan.interfaces = [ ];
    useDHCP = false;
    interfaces.br-lan = {
      ipv4.addresses = [{
        address = "10.10.0.2";
        prefixLength = 24;
      }];
      ipv6.addresses = [{
        address = "fd10:10:0::2";
        prefixLength = 64;
      }];
    };
    defaultGateway = {
      address = "10.10.0.1";
      interface = "br-lan";
    };
    defaultGateway6 = {
      address = "fd10:10:0::1";
      interface = "br-lan";
    };
    nameservers = [ "127.0.0.1" "::1" ];
    firewall.trustedInterfaces = [ "br-lan" ];
  };

  # Accept RAs on br-lan so we pick up the ISP-delegated GUA prefix. Keep
  # forwarding off on this host — OpnSense is the router.
  boot.kernel.sysctl = {
    "net.ipv6.conf.br-lan.accept_ra" = 2;
    "net.ipv6.conf.br-lan.autoconf" = 1;
  };
}
