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
  nat64 = import ../../../../../../modules/server/nat64-topology.nix { inherit secrets; };
  macAddress = "02:00:00:00:01:20";

  ciliumConfig = pkgs.replaceVars ./cilium-config.yaml.in {
    POD_CIDR = topology.cluster.podCidr;
    MTU = toString topology.cluster.mtu;
    KUBERNETES_API_HOST = topology.service.rke2Address;
  };

  traefikConfig = pkgs.replaceVars ./traefik-config.yaml.in {
    HTTP_NODE_PORT = toString topology.cluster.ingressHttpNodePort;
    FLOAT_PLAY_ADDRESS = secrets.privateIps.float-play.v6;
  };
in
{
  imports = [ ./flux ];

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
      default = "/run/hadal-bootstrap/token";
      description = "Optional agenix-backed RKE2 server token used for recovery and future node joins.";
    };
  };

  config = lib.mkIf cfg.enable {
    microvm.vms.rke2 = {
      inherit (cfg) autostart;
      config =
        {
          config,
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
              acceptRA = true;
              mtu = topology.cluster.mtu;
              bootstrapShare = true;
              routes = [
                {
                  Destination = nat64.prefix;
                  Gateway = topology.service.hostAddress;
                  # SLAAC also supplies a global address, but float-play only
                  # accepts the internal source prefixes over WireGuard.
                  PreferredSource = topology.service.rke2Address;
                }
                {
                  Destination = topology.infrastructure.prefix;
                  Gateway = topology.service.hostAddress;
                  # Infrastructure firewalls allow the fixed node ULA, not
                  # temporary addresses learned from router advertisements.
                  PreferredSource = topology.service.rke2Address;
                }
              ];
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
                  label = "vault-data";
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
              # The image's nft userspace crashes on rules created by the
              # newer NixOS firewall. Keep that firewall; use iptables for
              # Kubernetes service routing instead.
              mode = "iptables";
              bindAddress = topology.service.rke2Address;
              clusterCIDR = topology.cluster.podCidr;
              detectLocalMode = "ClusterCIDR";
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
              "--kube-controller-manager-arg=node-cidr-mask-size=64"
              "--disable-cloud-controller"
              "--egress-selector-mode=agent"
              "--ingress-controller=traefik"
              "--secrets-encryption-provider=aescbc"
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

          # Generic IPv6 MASQUERADE can choose a SLAAC global address, which
          # float-play does not accept over WireGuard. The node's route source
          # preference does not control forwarded pod masquerading. Own this
          # table separately and SNAT before Cilium's srcnat-priority chains;
          # do not modify Cilium-managed rules or NAT native IPv6 destinations.
          networking.nftables.tables.hadal_rke2_nat64 = {
            family = "ip6";
            content = ''
              chain postrouting {
                type nat hook postrouting priority srcnat - 1; policy accept;
                oifname "ens5" ip6 saddr ${topology.cluster.podCidr} ip6 daddr ${nat64.prefix} counter snat to ${topology.service.rke2Address} comment "RKE2 pod NAT64 uses the WireGuard-approved node ULA"
              }
            '';
          };

          # Forwarded pods do not inherit a route's PreferredSource when
          # Cilium applies MASQUERADE. Pin only the two infrastructure service
          # flows to the already-allowlisted node identity; keep other traffic
          # and Cilium's own tables unchanged.
          networking.nftables.tables.hadal_rke2_infrastructure = {
            family = "ip6";
            content = ''
              chain postrouting {
                type nat hook postrouting priority srcnat - 1; policy accept;
                oifname "ens5" ip6 saddr ${topology.cluster.podCidr} ip6 daddr ${topology.infrastructure.openbaoAddress} tcp dport 8200 counter snat to ${topology.service.rke2Address} comment "RKE2 pods to OpenBao use the allowlisted node ULA"
                oifname "ens5" ip6 saddr ${topology.cluster.podCidr} ip6 daddr ${topology.infrastructure.postgresqlAddress} tcp dport 5432 counter snat to ${topology.service.rke2Address} comment "RKE2 pods to PostgreSQL use the allowlisted node ULA"
              }
            '';
          };

          # Pod packets enter on lxc veths, but Cilium's aggregate return
          # route uses cilium_host. Keep strict RPF for other traffic.
          networking.firewall.extraReversePathFilterRules = ''
            iifname "lxc*" ip6 saddr ${topology.cluster.podCidr} counter accept comment "Cilium pod return routes use cilium_host"
          '';

          networking.firewall.extraInputRules = ''
            ip6 saddr ${topology.service.hostAddress}/128 tcp dport { 22, 6443 } accept
            ip6 saddr ${topology.infrastructure.hostAddress}/128 tcp dport { 22, 6443, 9345, 10250 } accept
            ip6 saddr ${topology.infrastructure.openbaoAddress}/128 tcp dport 6443 accept
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
