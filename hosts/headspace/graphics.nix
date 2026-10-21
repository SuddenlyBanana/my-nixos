{ lib, pkgs, ... }:

{
  hardware.graphics.enable = true;

  services.xserver.videoDrivers = lib.mkForce [ "modesetting" ];

  # nix-gaming-edge's prebuilt Mesa uses a newer glibc than this host's
  # applications, preventing EGL/GLX from loading. Use this host's Mesa.
  drivers.mesa-git.enable = false;

  # The firmware preference alone does not reliably select Intel on this
  # MacBook. Switch both the panel mux and console before greetd opens a GPU;
  # Hyprland renders LVDS-1 on Intel and disables Nouveau's LVDS-2 output.
  systemd.services.intel-panel = {
    description = "Route the MacBook panel and console to Intel";
    wantedBy = [ "multi-user.target" ];
    requiredBy = [ "greetd.service" ];
    after = [ "systemd-modules-load.service" "sys-kernel-debug.mount" ];
    before = [ "greetd.service" ];
    requires = [ "sys-kernel-debug.mount" ];
    # Do not repeat a completed boot-time switch during later rebuilds.
    restartIfChanged = false;
    unitConfig.ConditionPathExists = "/sys/kernel/debug/vgaswitcheroo/switch";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # A newly installed unit can also start during nixos-rebuild switch.
      # Skip it while greetd owns the session; ExecCondition exit 1 skips
      # cleanly, and the full switch will run before greetd on the next boot.
      ExecCondition = "${pkgs.bash}/bin/bash -c '! ${pkgs.systemd}/bin/systemctl --quiet is-active greetd.service'";
      ExecStart = lib.getExe (pkgs.writeShellApplication {
        name = "select-intel-panel";
        runtimeInputs = [ pkgs.gnugrep ];
        text = builtins.readFile ./select-intel-panel.sh;
      });
    };
  };

  environment.variables = {
    # Use NVK + Zink on Nouveau while keeping Intel's native Crocus driver.
    NOUVEAU_USE_ZINK = "1";
  };
}
