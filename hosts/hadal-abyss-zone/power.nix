{ pkgs, ... }:

let
  # NUT requires matching credentials even over loopback. This value is
  # intentionally not secret: upsd only accepts connections from this host.
  upsmonPasswordFile = pkgs.writeText "nut-upsmon-password" "hadal-ever-upsmon";
in
{
  power.ups = {
    enable = true;
    mode = "standalone";

    ups."ever-duo-pro-ii-800" = {
      description = "EVER DUO PRO II 800 (2 x 12 V 5 Ah VRLA batteries)";
      driver = "blazer_usb";
      port = "auto";

      directives = [
        # Allow the host enough time to finish shutting down before the UPS
        # removes output power. blazer_usb measures offdelay in seconds.
        "offdelay = 60"

        # Restore output three minutes after mains returns. blazer_usb measures
        # ondelay in minutes and warns that older firmware may reject values < 3.
        "ondelay = 3"

        # Derive LB from the configured charge threshold instead of trusting the
        # device's low-battery flag, which may arrive too late for a clean stop.
        # "override.battery.charge.low = 5"
        # "ignorelb"
      ];
    };

    # This is a standalone setup; do not expose the NUT data server to the LAN.
    upsd.listen = [
      { address = "127.0.0.1"; }
      { address = "::1"; }
    ];

    users.upsmon = {
      passwordFile = "${upsmonPasswordFile}";
      upsmon = "primary";
    };

    upsmon.monitor."ever-duo-pro-ii-800" = {
      system = "ever-duo-pro-ii-800@localhost";
      user = "upsmon";
      type = "primary";
    };
  };
}
