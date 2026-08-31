{ nix-gaming-edge, pkgs, ... }:

let
  steamGamemodeRun = pkgs.writeShellApplication {
    name = "steam-gamemode-run";
    runtimeInputs = [ pkgs.gamemode ];
    text = builtins.readFile (pkgs.replaceVars ./steam-gamemode-run {
      gamemodeLib64 = "${pkgs.gamemode.lib}/lib";
      gamemodeLib32 = "${pkgs.pkgsi686Linux.gamemode.lib}/lib";
    });
  };
in
{
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
}
