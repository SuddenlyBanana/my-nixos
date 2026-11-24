{ secrets, ... }:

let
  windowsMoe = secrets.zones.float-play.windowsMoeZone.name;
  mail = import ../../../../../modules/server/mail-topology.nix { inherit secrets; };
  websiteDomain = secrets.zones.float-play.domain1Zone.name;
  wapHost = "wap.${websiteDomain}";
  wwwHost = "www.${websiteDomain}";
  vaultHost = "vault.${windowsMoe}";
  rke2Address = "${secrets.privateIps.prefixes.homelabUla}:9::20";
  rke2IngressHttpPort = 30080;
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

      listen = [
        {
          addr = secrets.publicIps.float-play.v4;
          port = 80;
        }
      ];

      locations."/" = {
        proxyPass = "http://[${rke2Address}]:${toString rke2IngressHttpPort}";
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
      locations."/".proxyPass = "http://[${rke2Address}]:${toString rke2IngressHttpPort}";
    };

    virtualHosts.${mail.hostname} = {
      listenAddresses = [ secrets.publicIps.float-play.v4 "[${secrets.publicIps.float-play.v6}]" ];
      serverAliases = map (name: "${name}.${mail.domain}") [ "autoconfig" "autodiscover" "mta-sts" "ua-auto-config" ];
      enableACME = true;
      forceSSL = true;
      # Serve nginx's own HTTP-01 tokens first, then Stalwart's tokens. This
      # lets both TLS endpoints renew without forwarding the setup UI.
      acmeFallbackHost = "[${rke2Address}]:30808";
      locations."/" = {
        proxyPass = "https://[${rke2Address}]:30443";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_bind ${mail.relayAddress};
          proxy_ssl_server_name on;
          proxy_ssl_name ${mail.hostname};
          proxy_ssl_verify on;
          # ACME chains can include cross-signed roots as well as intermediates.
          proxy_ssl_verify_depth 4;
          proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
          proxy_cache off;
        '';
      };
      extraConfig = ''
        add_header Cache-Control "no-store" always;
      '';
    };

    # Serve the placeholder locally. Stalwart's domain certificate also covers
    # the apex, so retain its HTTP-01 fallback alongside nginx's own tokens.
    virtualHosts.${mail.domain} = {
      listenAddresses = [ secrets.publicIps.float-play.v4 "[${secrets.publicIps.float-play.v6}]" ];
      enableACME = true;
      addSSL = true;
      acmeFallbackHost = "[${rke2Address}]:30808";
      extraConfig = "proxy_bind ${mail.relayAddress};";
      root = ./teleinfotek;
      locations."/".tryFiles = "$uri $uri/ =404";
    };

    virtualHosts.${vaultHost} = {
      listenAddresses = [
        secrets.publicIps.float-play.v4
        "[${secrets.publicIps.float-play.v6}]"
      ];
      enableACME = true;
      forceSSL = true;
      extraConfig = ''
        access_log off;
        add_header Referrer-Policy no-referrer always;
        add_header Cache-Control "no-store" always;
      '';
      locations = {
        "/".proxyPass = "http://[${rke2Address}]:${toString rke2IngressHttpPort}";
        "= /notifications/anonymous-hub" = {
          proxyPass = "http://[${rke2Address}]:${toString rke2IngressHttpPort}";
          proxyWebsockets = true;
        };
        "= /notifications/hub" = {
          proxyPass = "http://[${rke2Address}]:${toString rke2IngressHttpPort}";
          proxyWebsockets = true;
        };
      };
    };

    virtualHosts.${websiteDomain} = {
      listenAddresses = [
        secrets.publicIps.float-play.v4
        "[${secrets.publicIps.float-play.v6}]"
      ];
      enableACME = true;
      addSSL = true;
      locations."/".return = "301 https://${wwwHost}$request_uri";
    };

    virtualHosts.${wwwHost} = {
      listenAddresses = [
        secrets.publicIps.float-play.v4
        "[${secrets.publicIps.float-play.v6}]"
      ];
      enableACME = true;
      forceSSL = true;
      locations."/".proxyPass = "http://[${rke2Address}]:${toString rke2IngressHttpPort}";
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
