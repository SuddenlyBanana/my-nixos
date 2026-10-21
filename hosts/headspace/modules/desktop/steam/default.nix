{ nix-gaming-edge, pkgs, ... }:

let
  steamGpuPstate = pkgs.writeShellApplication {
    name = "steam-gpu-pstate";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./steam-gpu-pstate;
  };
  steamGamemodeRun = pkgs.writeShellApplication {
    name = "steam-gamemode-run";
    runtimeInputs = [ pkgs.gamemode ];
    text = builtins.readFile (
      pkgs.replaceVars ./steam-gamemode-run {
        gamemodeLib64 = "${pkgs.gamemode.lib}/lib";
        gamemodeLib32 = "${pkgs.pkgsi686Linux.gamemode.lib}/lib";
        systemctl = "${pkgs.systemd}/bin/systemctl";
      }
    );
  };
in
{
  systemd.services.steam-gpu-pstate = {
    description = "Set the Nouveau GT 650M performance state for Steam";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${steamGpuPstate}/bin/steam-gpu-pstate 0e";
    };
  };

  systemd.services.steam-gpu-pstate-low = {
    description = "Return the Nouveau GT 650M to its low-power state";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${steamGpuPstate}/bin/steam-gpu-pstate 07";
    };
  };

  security.polkit = {
    enable = true;
    extraConfig = builtins.readFile ./steam-gpu-pstate.rules;
  };

  programs = {
    steam = {
      enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = true;
      extraCompatPackages = [
        nix-gaming-edge.packages.${pkgs.stdenv.hostPlatform.system}.proton-cachyos
      ];
      gamescopeSession.enable = true;
      package = pkgs.steam.override {
        extraPkgs =
          pkgs': with pkgs'; [
            gamemode
            gamemode.lib
            steamGamemodeRun
          ];
      };
    };
    gamemode.enable = true;
    gamescope = {
      enable = true;
      # Steam's pressure-vessel sandbox cannot inherit this file capability.
      # Gamescope works without it, but has no real-time scheduling privilege.
      capSysNice = false;
    };
  };

  hardware = {
    xpadneo.enable = true;
    steam-hardware.enable = true;
  };

  nix.settings = {
    substituters = [ "https://nix-cache.tokidoki.dev/tokidoki" ];
    trusted-public-keys = [ "tokidoki:MD4VWt3kK8Fmz3jkiGoNRJIW31/QAm7l1Dcgz2Xa4hk=" ];
  };
}
