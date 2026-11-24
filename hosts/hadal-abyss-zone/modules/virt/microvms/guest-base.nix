{
  hostName,
  address,
  hostAddress,
  macAddress,
  tapId,
  vsockCid,
  mem,
  vcpu,
  volumes ? [ ],
  mtu ? 9000,
  acceptRA ? false,
  routes ? [ ],
  bootstrapShare ? false,
}:

{
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./operator-access.nix ];

  networking = {
    inherit hostName;
    useDHCP = false;
    useNetworkd = true;
    networkmanager.enable = lib.mkForce false;
    nameservers = [ hostAddress ];
    hosts."::1" = [
      "localhost"
      hostName
    ];
    nftables.enable = true;
    firewall.enable = true;
  };

  systemd.network = {
    enable = true;
    wait-online.enable = true;
    networks."20-primary" = {
      matchConfig.MACAddress = macAddress;
      linkConfig.MTUBytes = toString mtu;
      address = [ "${address}/64" ];
      inherit routes;
      networkConfig = {
        DHCP = "no";
        IPv6AcceptRA = acceptRA;
      };
      ipv6AcceptRAConfig = lib.mkIf acceptRA {
        UseDNS = false;
        UseMTU = false;
      };
    };
  };

  microvm = {
    hypervisor = "cloud-hypervisor";
    inherit mem vcpu volumes;
    storeOnDisk = true;
    shares = lib.optional bootstrapShare {
      proto = "virtiofs";
      source = "/run/hadal-bootstrap/${if hostName == "rke2-server" then "rke2" else hostName}";
      mountPoint = "/run/hadal-bootstrap";
      tag = "bootstrap";
      readOnly = true;
      cache = "never";
    };
    vsock.cid = vsockCid;
    interfaces = [
      {
        type = "tap";
        id = tapId;
        mac = macAddress;
      }
    ];
  };

  boot = {
    supportedFilesystems = [ "xfs" ];
    kernelModules = [ "xfs" ];
  };

  environment.systemPackages = [ pkgs.xfsprogs ];

  services.journald.extraConfig = ''
    ForwardToConsole=yes
    TTYPath=/dev/console
    MaxLevelConsole=notice
  '';

  system.stateVersion = "26.05";
}
