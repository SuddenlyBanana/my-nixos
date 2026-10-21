{ config, ... }:

{
  virtualisation.oci-containers.containers.unifi = {
    image = "docker.io/jacobalberty/unifi:v10.0.162";
    environment = {
      TZ = config.time.timeZone;
      JVM_MAX_HEAP_SIZE = "1024M";
      UNIFI_STDOUT = "true";
    };
    volumes = [ "/var/lib/unifi:/unifi" ];
    extraOptions = [
      "--network=host"
      "--init"
      "--user=999:999"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/unifi 0750 999 999 -"
    "d /var/lib/unifi/data 0750 999 999 -"
    "d /var/lib/unifi/log 0750 999 999 -"
    "d /var/lib/unifi/cert 0750 999 999 -"
    "d /var/lib/unifi/init.d 0750 999 999 -"
  ];

  networking.firewall = {
    allowedTCPPorts = [
      8080 # Device inform
      8443 # Web UI and API
    ];
    allowedUDPPorts = [
      3478 # STUN
      10001 # Device discovery
    ];
  };
}
