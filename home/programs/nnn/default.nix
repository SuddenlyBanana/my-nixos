{ pkgs, ... }:

{
  programs.nnn = {
    enable = true;
    enableFishIntegration = true;
    options = {
      # preview-tui requires the FIFO created by -a. Run it at startup as well;
      # mappings only assigns the plugin key and does not enable previews.
      a = true;
      P = "p";
    };

    plugins = {
      src = pkgs.nnn + "/share/plugins";
      mappings.p = "preview-tui";
    };

    extraPackages = with pkgs; [
      file
      tree
      mediainfo
      imagemagick
      ffmpeg
      ffmpegthumbnailer
      mpv
    ];
  };
}
