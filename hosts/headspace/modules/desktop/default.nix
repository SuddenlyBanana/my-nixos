{ lib, pkgs, tuigreet, ... }:

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
    hyprland.enable = true;
    nm-applet.enable = true;
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
      command = "${lib.getExe tuigreet.packages.${pkgs.stdenv.hostPlatform.system}.tuigreet} --time --remember --remember-session --cmd ${lib.getExe' pkgs.hyprland "start-hyprland"}";
      user = "greeter";
    };
  };

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];

  security.rtkit.enable = true;

  environment.systemPackages = with pkgs; [ vulkan-tools mesa-demos ];
}
