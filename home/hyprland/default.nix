{ pkgs, ... }:

{
  wayland.windowManager.hyprland = {
    enable = true;

    # Packaged with the same Nixpkgs revision as Hyprland, so its plugin ABI
    # always matches the compositor we install.
    plugins = [ pkgs.hyprlandPlugins.hyprspace ];

    settings = {
      "$mod" = "SUPER";
      bind = [
        "$mod, return, exec, kitty"
        "$mod, q, killactive"
        "$mod SHIFT, c, forcekillactive"
        "$mod, w, overview:toggle"
      ] ++ (builtins.concatLists (builtins.genList (x:
        let ws = let c = (x + 1) / 10; in builtins.toString (x + 1 - (c * 10));
        in [
          "$mod, ${ws}, workspace, ${toString (x + 1)}"
          "$mod SHIFT, ${ws}, movetoworkspace, ${toString (x + 1)}"
        ]) 10));

      # Native, interactive workspace switching.  Hyprspace also listens for
      # three-finger vertical swipes: swipe up to open its macOS-like overview
      # and down to close it.  Four fingers remains available for horizontal
      # workspace switching, but the overview itself uses three fingers.
      gesture = [
        "3, horizontal, workspace"
        "4, horizontal, workspace"
      ];

      plugin.overview = {
        centerAligned = true;
        showNewWorkspace = true;
        autoDrag = true;
        exitOnClick = true;
        exitOnSwitch = true;
        reverseSwipe = true;
      };

      # Workaround for double internal screens on MacbookPro9,1
      monitor = [
        "LVDS-2,1440x900@59.90,0x0,1"
        "LVDS-1,1440x900@59.90,0x0,1,mirror,LVDS-2"
      ];
    };
  };
}
