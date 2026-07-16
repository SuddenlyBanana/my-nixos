{ ... }:

let
  # Well-known NAT64 prefix (RFC 6052 / RFC 6146).
  # DNS64 on the server LAN must synthesize AAAA records into this prefix
  # for NAT64 to catch outbound v6-to-v4 traffic.
  pool6 = "64:ff9b::/96";

  # IPv4 address(es) Jool SNATs translated traffic to.
  # Set this to the VPS's public IPv4 once known.
  pool4Addr = "64.176.71.121";
in {
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # Route pool6 to loopback so the kernel accepts these packets for
  # local processing — Jool (netfilter mode) intercepts before routing.
  systemd.network.networks."10-nat64-route" = {
    matchConfig.Name = "lo";
    routes = [{
      Destination = pool6;
      Type = "local";
    }];
  };

  networking.jool = {
    enable = true;
    nat64.default = {
      framework = "netfilter";
      global.pool6 = pool6;
      pool4 = [
        {
          protocol = "TCP";
          prefix = "${pool4Addr}/32";
          "port range" = "40001-65535";
        }
        {
          protocol = "UDP";
          prefix = "${pool4Addr}/32";
          "port range" = "40001-65535";
        }
        {
          protocol = "ICMP";
          prefix = "${pool4Addr}/32";
          "port range" = "1-65535";
        }
      ];
    };
  };
}
