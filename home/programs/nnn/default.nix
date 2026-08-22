{ pkgs, ... }:

{
  programs.nnn = {
    enable = true;
    enableFishIntegration = true;
    options.a = true;

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
