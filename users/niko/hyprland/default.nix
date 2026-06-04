{ ... }:

{
  wayland.windowManager.hyprland = {
    enable = true;

    settings = {
      "$mod" = "SUPER";
      bind =
        [
	  "$mod, return, exec, kitty"
	  "$mod, q, killactive"
	  "$mod SHIFT, c, forcekillactive"
	]
	++ (
	  builtins.concatLists (builtins.genList (
	    x: let
	      ws = let
	        c = (x + 1) / 10;
	      in
	        builtins.toString (x + 1 - (c * 10));
	    in [
	      "$mod, ${ws}, workspace, ${toString (x + 1)}"
	      "$mod SHIFT, ${ws}, movetoworkspace, ${toString (x + 1)}"
	    ]
	  )
	  10)
	);
      # Workaround for double internal screens on MacbookPro9,1
      monitor = [
        "LVDS-2,1440x900@59.90,0x0,1"
	"LVDS-1,1440x900@59.90,0x0,1,mirror,LVDS-2"
      ];
    };
  };
}
