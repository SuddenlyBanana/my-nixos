{ lib, pkgs, ... }:

{
  imports = [ ./steam ];

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
    k3b.enable = true;
  };

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [ "hyprland" "gtk" ];
  };

  # TLP owns the laptop's power-policy tuning and conflicts with
  # power-profiles-daemon.  Its compatible D-Bus bridge lets desktop power
  # profile controls switch TLP profiles.
  services.power-profiles-daemon.enable = false;
  services.tlp = {
    enable = true;
    pd.enable = true;
  };

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
  security.sudo.wheelNeedsPassword = false;

  # KDE applications running outside Plasma still need an XDG menu definition
  # for KService/KSycoca to discover desktop applications.
  environment.etc."xdg/menus/applications.menu".source =
    "${pkgs.kdePackages.plasma-workspace}/etc/xdg/menus/plasma-applications.menu";

  # KIO's MTP worker activates `org.kde.kmtpd5` over D-Bus.  Its activation
  # entry must be visible to the session bus, so this cannot live solely in
  # Home Manager's user profile.
  environment.systemPackages = with pkgs; [
    vulkan-tools
    mesa-demos
    kdePackages.kio-extras
  ];
}
