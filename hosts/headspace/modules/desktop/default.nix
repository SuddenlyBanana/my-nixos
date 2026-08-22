{ lib, pkgs, ... }:

{
  services = {
    pipewire = {
      enable = true;
      alsa = {
        enable = true;
        support32Bit = true;
      };

      pulse.enable = true;
    };

    printing.enable = true;
    udisks2.enable = true;
    gvfs.enable = true;
    gnome.gnome-keyring.enable = true;

    geoclue2 = {
      enable = true;
      appConfig.gammastep = {
        isAllowed = true;
        isSystem = false;
      };
    };
  };

  programs = {
    hyprland = {
      enable = true;
      withUWSM = true;
    };
    uwsm.enable = true;
    nm-applet.enable = true;
    kdeconnect.enable = true;
  };

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [ "hyprland" "gtk" ];
  };

  services.power-profiles-daemon.enable = true;

  networking.firewall = {
    allowedTCPPortRanges = [{ from = 1714; to = 1764; }];
    allowedUDPPortRanges = [{ from = 1714; to = 1764; }];
  };

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  services.blueman.enable = true;

  # BlueZ's default OBEX service has no receive directory. Accept files from
  # paired devices into the logged-in user's Downloads directory.
  systemd.user.services.obex = {
    description = "Bluetooth OBEX file receiver";
    serviceConfig = {
      Type = "dbus";
      BusName = "org.bluez.obex";
      ExecStart = "${pkgs.bluez}/libexec/bluetooth/obexd --root=%h/Downloads --auto-accept";
    };
  };

  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${lib.getExe pkgs.tuigreet} --time --remember --remember-session --cmd '${lib.getExe pkgs.uwsm} start hyprland-uwsm.desktop'";
      user = "greeter";
    };
  };

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts-color-emoji
  ];

  security.rtkit.enable = true;

  environment.systemPackages = with pkgs; [ vulkan-tools mesa-demos ];
}
