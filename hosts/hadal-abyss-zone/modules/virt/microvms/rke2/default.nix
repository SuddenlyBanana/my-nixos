{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  cfg = config.hadal.microvms.rke2;
  topology = import ../topology.nix { inherit secrets; };
  macAddress = "02:00:00:00:01:20";

  ciliumConfig = pkgs.replaceVars ./cilium-config.yaml.in {
    POD_CIDR = topology.cluster.podCidr;
  };

  traefikConfig = pkgs.replaceVars ./traefik-config.yaml.in {
    HTTP_NODE_PORT = toString topology.cluster.ingressHttpNodePort;
    FLOAT_PLAY_ADDRESS = secrets.privateIps.float-play.v6;
  };
in
{
  options.hadal.microvms.rke2 = {
    enable = lib.mkEnableOption "the RKE2 server MicroVM";

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start RKE2 automatically after both production LVs are available.";
    };

    stateDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/hadal-vm/rke2-state";
      description = "Raw host block device containing the XFS RKE2 state filesystem.";
    };

    vaultwardenDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/hadal-vm/vaultwarden-data";
      description = "Raw host block device exposed as the Vaultwarden local PV.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional agenix-backed RKE2 server token used for recovery and future node joins.";
    };

    mtu = lib.mkOption {
      type = lib.types.ints.between 1280 9000;
      default = 1280;
      description = "Conservative initial node MTU; replace it with the result of the end-to-end PMTU test.";
    };
  };

  config = lib.mkIf cfg.enable {
    microvm.vms.rke2 = {
      inherit (cfg) autostart;
      config =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        {
          imports = [
            (import ../guest-base.nix {
              hostName = "rke2-server";
              address = topology.service.rke2Address;
              hostAddress = topology.service.hostAddress;
              inherit macAddress;
              tapId = "vm-web-20";
              vsockCid = 22;
              mem = 8192;
              vcpu = 4;
              mtu = cfg.mtu;
              acceptRA = true;
              volumes = [
                {
                  image = cfg.stateDevice;
                  mountPoint = "/var/lib/rancher/rke2";
                  label = "rke2-state";
                  size = 131072;
                  fsType = "xfs";
                  autoCreate = false;
                  direct = true;
                }
                {
                  image = cfg.vaultwardenDevice;
                  mountPoint = "/var/lib/hadal-pv/vaultwarden";
                  label = "vaultwarden-data";
                  size = 32768;
                  fsType = "xfs";
                  autoCreate = false;
                  direct = true;
                }
              ];
            })
          ];

          boot.kernelModules = [
            "br_netfilter"
            "nf_conntrack"
            "overlay"
            "vxlan"
          ];

          boot.kernel.sysctl = {
            "net.bridge.bridge-nf-call-ip6tables" = 1;
            "net.bridge.bridge-nf-call-iptables" = 1;
            "net.ipv4.ip_forward" = 0;
            "net.ipv6.conf.all.forwarding" = 1;
            "net.ipv6.conf.all.accept_ra" = 2;
          };

          environment.systemPackages = [
            pkgs.cilium-cli
            pkgs.kubectl
          ];

          services.rke2 = {
            enable = true;
            role = "server";
            cni = "cilium";
            cisHardening = true;
            nodeName = "hadal-rke2-1";
            nodeIP = topology.service.rke2Address;
            tokenFile = cfg.tokenFile;
            images = [
              config.services.rke2.package.images-core-linux-amd64-tar-zst
              config.services.rke2.package.images-cilium-linux-amd64-tar-zst
              config.services.rke2.package.images-traefik-linux-amd64-tar-zst
            ];
            extraKubeProxyConfig = {
              mode = "nftables";
              clientConnection.kubeconfig = "/var/lib/rancher/rke2/agent/kubeproxy.kubeconfig";
            };
            manifests = {
              rke2-cilium-config.source = ciliumConfig;
              rke2-traefik-config.source = traefikConfig;
            };
            extraFlags = [
              "--advertise-address=${topology.service.rke2Address}"
              "--bind-address=${topology.service.rke2Address}"
              "--cluster-cidr=${topology.cluster.podCidr}"
              "--service-cidr=${topology.cluster.serviceCidr}"
              "--cluster-dns=${topology.cluster.dnsAddress}"
              "--cluster-domain=cluster.local"
              "--node-cidr-mask-size-ipv6=64"
              "--disable-cloud-controller"
              "--egress-selector-mode=agent"
              "--ingress-controller=traefik"
              "--secrets-encryption"
              "--audit-policy-file=${./audit-policy.yaml}"
              "--kube-apiserver-arg=audit-log-maxage=30"
              "--kube-apiserver-arg=audit-log-maxbackup=10"
              "--kube-apiserver-arg=audit-log-maxsize=100"
              "--pod-security-admission-config-file=${./psa.yaml}"
              "--etcd-snapshot-retention=14"
              "--tls-san=${topology.service.rke2Address}"
              "--write-kubeconfig-mode=0640"
            ];
          };

          systemd.services.rke2-server.unitConfig.RequiresMountsFor = [
            "/var/lib/rancher/rke2"
            "/var/lib/hadal-pv/vaultwarden"
          ];

          networking.firewall.extraInputRules = ''
            ip6 saddr ${topology.infrastructure.hostAddress}/128 tcp dport { 22, 6443, 9345, 10250 } accept
            ip6 saddr ${secrets.privateIps.float-play.v6}/128 tcp dport ${toString topology.cluster.ingressHttpNodePort} accept
            ip6 saddr ${topology.service.hostAddress}/128 tcp dport ${toString topology.cluster.ingressHttpNodePort} accept
            ip6 saddr ${topology.cluster.podCidr} accept
          '';
        };
    };

    systemd.services."microvm@rke2".unitConfig.ConditionPathIsBlockDevice = [
      cfg.stateDevice
      cfg.vaultwardenDevice
    ];
  };
}
