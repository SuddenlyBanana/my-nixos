{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  nat64 = import ../../../../../modules/server/nat64-topology.nix { inherit secrets; };
  firewall = pkgs.replaceVars ./firewall.sh {
    XTABLES_LIBDIR = "${
      pkgs.buildEnv {
        name = "jool-xtables";
        paths = [
          pkgs.iptables.lib
          pkgs.jool-cli
        ];
        pathsToLink = [ "/lib/xtables" ];
      }
    }/lib/xtables";
    IPV6_SOURCES = builtins.concatStringsSep " " nat64.clientPrefixes;
    PUBLIC_IPV4 = secrets.publicIps.float-play.v4;
    PREFIX = nat64.prefix;
  };
in
{
  assertions = [
    {
      assertion = !config.networking.nftables.enable;
      message = "The scoped Jool iptables target currently requires float-play's iptables firewall backend.";
    }
  ];
  networking.jool = {
    enable = true;
    # Explicit iptables matches constrain translation BEFORE Jool bypasses
    # FORWARD. Never attach an unrestricted translator to the public NIC.
    nat64.hadal = {
      framework = "iptables";
      global.pool6 = nat64.prefix;
      pool4 =
        map
          (protocol: {
            inherit protocol;
            prefix = "${secrets.publicIps.float-play.v4}/32";
            "port range" = "61001-65535";
          })
          [
            "TCP"
            "UDP"
            "ICMP"
          ];
    };
  };

  # The firewall starts before network.target/Jool's instance service. The
  # JOOL target must already be registered when its scoped rules are installed.
  boot.kernelModules = [ "jool" ];
  systemd.services.firewall.after = [ "systemd-modules-load.service" ];

  # The booted generation may not include Jool yet. Use this generation's
  # module tree; modprobe still requires modules for the running kernel.
  systemd.services.systemd-modules-load.environment.MODULE_DIR =
    "${config.system.modulesTree}/lib/modules";
  systemd.services.jool-nat64-hadal.environment.MODULE_DIR =
    "${config.system.modulesTree}/lib/modules";

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = lib.mkDefault 1;
    "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
    # Jool and local sockets share this public IPv4 address.
    "net.ipv4.ip_local_reserved_ports" = "61001-65535";
  };

  # Jool's scoped rules use the NixOS iptables firewall hooks.
  networking.nftables.enable = lib.mkForce false;
  networking.firewall = {
    extraCommands = "${pkgs.bash}/bin/bash ${firewall} start";
    extraStopCommands = "${pkgs.bash}/bin/bash ${firewall} stop";
  };
}
