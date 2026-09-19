{ wapmail, secrets, ... }:

let
  site = wapmail.packages.x86_64-linux.default;
  php = wapmail.packages.x86_64-linux.php;
  guestAddress = "fd8b:9dca:b9ce:1::10";
  hostAddress = "fd8b:9dca:b9ce:1::1";
  macAddress = "02:00:00:00:01:10";
in
{
  microvm.vms.wapmail.config = { config, pkgs, ... }: {
    networking.hostName = "wapmail";
    system.stateVersion = "26.05";

    microvm = {
      hypervisor = "firecracker";
      mem = 512;
      vcpu = 1;
      storeOnDisk = true;
      interfaces = [{
        type = "tap";
        id = "vm-web-01";
        mac = macAddress;
      }];
    };

    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.nameservers = [ hostAddress ];
    services.journald.extraConfig = ''
      ForwardToConsole=yes
      TTYPath=/dev/console
      MaxLevelConsole=notice
    '';
    systemd.network.networks."20-web" = {
      matchConfig.MACAddress = macAddress;
      linkConfig.MTUBytes = "1280";
      address = [ "${guestAddress}/64" ];
      routes = [{ Gateway = hostAddress; }];
      networkConfig = {
        DHCP = "no";
        IPv6AcceptRA = false;
      };
    };

    services.phpfpm.pools.wapmail = {
      phpPackage = php;
      user = "nginx";
      group = "nginx";
      phpOptions = ''
        session.save_path = /run/wapmail-sessions
        expose_php = Off
        log_errors = On
        error_log = syslog
      '';
      settings = {
        "pm" = "ondemand";
        "pm.max_children" = 4;
        "pm.process_idle_timeout" = "30s";
        "listen.owner" = "nginx";
        "listen.group" = "nginx";
      };
    };
    systemd.tmpfiles.rules = [ "d /run/wapmail-sessions 0700 nginx nginx -" ];

    services.nginx = {
      enable = true;
      validateConfigFile = true;
      virtualHosts."wap.${secrets.zones.float-play.domain1.name}" = {
        default = true;
        listen = [{ addr = "[::]"; port = 80; }];
        root = "${site}/public";
        extraConfig = ''
          access_log off;
          add_header Referrer-Policy no-referrer always;
        '';
        locations."/" = {
          index = "index.php";
          extraConfig = ''
            try_files $uri $uri/ =404;
          '';
        };
        locations."~ \\.php$".extraConfig = ''
          try_files $uri =404;
          include ${pkgs.nginx}/conf/fastcgi_params;
          fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
          fastcgi_pass unix:${config.services.phpfpm.pools.wapmail.socket};
        '';
      };
    };
    networking.firewall.allowedTCPPorts = [ 80 ];
  };
}
