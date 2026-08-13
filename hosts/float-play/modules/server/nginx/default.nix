{ secrets, ... }:

let upstreamHost = "[fd99:0::2]";
in {
  services.nginx = {
    enable = true;

    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    proxyCachePath."default" = {
      enable = true;
      keysZoneName = "default";
      keysZoneSize = "50m";
      maxSize = "10g";
      inactive = "1d";
      levels = "1:2";
    };

    virtualHosts."_" = {
      default = true;

      # The relay owns the public IPv4 address, so Nginx receives public
      # HTTP directly. No inbound DNAT/NAT46 is involved; the upstream is
      # reached over the IPv6 WireGuard tunnel.
      listen = [{
        addr = secrets.publicIps.float-play.v4;
        port = 80;
      }];

      locations."/" = {
        proxyPass = "http://${upstreamHost}";
        extraConfig = ''
          proxy_cache default;
          proxy_cache_valid 200 302 10m;
          proxy_cache_valid 404 1m;
          proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
          add_header X-Cache-Status $upstream_cache_status;
        '';
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
