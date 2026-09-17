{ secrets, ... }:

let
  wapHost = "wap.${secrets.zones.float-play.domain1.name}";
in
{
  security.acme = {
    acceptTerms = true;
    defaults.email = "SuddenlyBanana@proton.me";
  };

  services.nginx = {
    enable = true;

    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    appendHttpConfig = ''
      map $host $access_log_enabled {
        default 1;
        ${wapHost} 0;
      }
      access_log /var/log/nginx/access.log combined if=$access_log_enabled;
    '';

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

      listen = [{
        addr = secrets.publicIps.float-play.v4;
        port = 80;
      }];

      locations."/" = {
        proxyPass = "http://[${secrets.privateIps.hadal-abyss-zone.wg-tunnel.v6}]";
        extraConfig = ''
          proxy_cache default;
          proxy_cache_valid 200 302 10m;
          proxy_cache_valid 404 1m;
          proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
          add_header X-Cache-Status $upstream_cache_status;
        '';
      };
    };

    virtualHosts.${wapHost} = {
      listenAddresses = [ secrets.publicIps.float-play.v4 ];
      enableACME = true;
      addSSL = true;
      extraConfig = ''
        access_log off;
        add_header Referrer-Policy no-referrer always;
        add_header Cache-Control "no-store" always;
      '';
      locations."/".proxyPass = "http://[fd8b:9dca:b9ce:1::10]:80";
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
