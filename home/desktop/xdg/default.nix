{ config, lib, pkgs, ... }:

{
  xdg = {
    enable = true;
    mime.enable = true;
    dataFile = {
      "applications/org.kde.dolphin.desktop".source =
        "${pkgs.kdePackages.dolphin}/share/applications/org.kde.dolphin.desktop";
      "applications/org.niko.gwenview.desktop".source = ./gwenview.desktop;
      "applications/org.niko.okular.desktop".source = ./okular.desktop;
      "applications/org.niko.ark.desktop".source = ./ark.desktop;
      "applications/org.niko.kate.desktop".source = ./kate.desktop;
      "applications/org.niko.darktable.desktop".source = ./darktable.desktop;
      "applications/org.kicad.kicad.desktop".source = ./kicad.desktop;
      "applications/org.kicad.eeschema.desktop".source = ./eeschema.desktop;
      "applications/org.kicad.pcbnew.desktop".source = ./pcbnew.desktop;
      "applications/org.kicad.gerbview.desktop".source = ./gerbview.desktop;
      "applications/org.kicad.pcb_calculator.desktop".source = ./pcb_calculator.desktop;
      "applications/org.kicad.pl_editor.desktop".source = ./pl_editor.desktop;
      "applications/org.kicad.bitmap2component.desktop".source = ./bitmap2component.desktop;
      "applications/mpv.desktop".source =
        "${config.programs.mpv.package}/share/applications/mpv.desktop";
      "applications/zen-twilight.desktop".source =
        "${config.programs.zen-browser.package}/share/applications/zen-twilight.desktop";
    };
    mimeApps = rec {
      enable = true;
      defaultApplications = {
        "inode/directory" = "org.kde.dolphin.desktop";

        "text/html" = "zen-twilight.desktop";
        "application/xhtml+xml" = "zen-twilight.desktop";
        "x-scheme-handler/http" = "zen-twilight.desktop";
        "x-scheme-handler/https" = "zen-twilight.desktop";

        # Images
        "image/avif" = "org.niko.gwenview.desktop";
        "image/bmp" = "org.niko.gwenview.desktop";
        "image/gif" = "org.niko.gwenview.desktop";
        "image/heic" = "org.niko.gwenview.desktop";
        "image/heif" = "org.niko.gwenview.desktop";
        "image/jpeg" = "org.niko.gwenview.desktop";
        "image/png" = "org.niko.gwenview.desktop";
        "image/svg+xml" = "org.niko.gwenview.desktop";
        "image/tiff" = "org.niko.gwenview.desktop";
        "image/webp" = "org.niko.gwenview.desktop";

        # Camera RAW formats
        "image/x-adobe-dng" = "org.niko.darktable.desktop";
        "image/x-canon-cr2" = "org.niko.darktable.desktop";
        "image/x-canon-cr3" = "org.niko.darktable.desktop";
        "image/x-epson-erf" = "org.niko.darktable.desktop";
        "image/x-fuji-raf" = "org.niko.darktable.desktop";
        "image/x-kodak-dcr" = "org.niko.darktable.desktop";
        "image/x-nikon-nef" = "org.niko.darktable.desktop";
        "image/x-olympus-orf" = "org.niko.darktable.desktop";
        "image/x-panasonic-rw2" = "org.niko.darktable.desktop";
        "image/x-pentax-pef" = "org.niko.darktable.desktop";
        "image/x-raw" = "org.niko.darktable.desktop";
        "image/x-sigma-x3f" = "org.niko.darktable.desktop";
        "image/x-sony-arw" = "org.niko.darktable.desktop";

        # Documents and ebooks
        "application/pdf" = "org.niko.okular.desktop";
        "application/epub+zip" = "org.niko.okular.desktop";
        "application/postscript" = "org.niko.okular.desktop";
        "application/vnd.ms-xpsdocument" = "org.niko.okular.desktop";
        "image/vnd.djvu" = "org.niko.okular.desktop";
        "image/vnd.djvu+multipage" = "org.niko.okular.desktop";

        # Plain text and developer files
        "application/json" = "org.niko.kate.desktop";
        "application/toml" = "org.niko.kate.desktop";
        "application/xml" = "org.niko.kate.desktop";
        "application/x-shellscript" = "org.niko.kate.desktop";
        "text/css" = "org.niko.kate.desktop";
        "text/csv" = "org.niko.kate.desktop";
        "text/markdown" = "org.niko.kate.desktop";
        "text/plain" = "org.niko.kate.desktop";
        "text/x-c++src" = "org.niko.kate.desktop";
        "text/x-csrc" = "org.niko.kate.desktop";
        "text/x-python" = "org.niko.kate.desktop";
        "text/x-yaml" = "org.niko.kate.desktop";

        # Media
        "audio/flac" = "mpv.desktop";
        "audio/mpeg" = "mpv.desktop";
        "audio/ogg" = "mpv.desktop";
        "audio/opus" = "mpv.desktop";
        "audio/wav" = "mpv.desktop";
        "video/mp4" = "mpv.desktop";
        "video/mpeg" = "mpv.desktop";
        "video/ogg" = "mpv.desktop";
        "video/webm" = "mpv.desktop";
        "video/x-matroska" = "mpv.desktop";

        # Archives and disk images
        "application/zip" = "org.niko.ark.desktop";
        "application/gzip" = "org.niko.ark.desktop";
        "application/x-7z-compressed" = "org.niko.ark.desktop";
        "application/x-bzip2" = "org.niko.ark.desktop";
        "application/x-bzip-compressed-tar" = "org.niko.ark.desktop";
        "application/x-compressed-tar" = "org.niko.ark.desktop";
        "application/x-iso9660-image" = "org.niko.ark.desktop";
        "application/x-rar" = "org.niko.ark.desktop";
        "application/x-tar" = "org.niko.ark.desktop";
        "application/x-xz" = "org.niko.ark.desktop";
      };
      associations.added = lib.mapAttrs (_: application: [ application ]) defaultApplications;
    };
  };

  # Dolphin consults the XDG desktop database when populating its Open With
  # menu. Home Manager links the entries above but does not build this cache.
  home.activation.updateDesktopDatabase = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    $DRY_RUN_CMD ${pkgs.desktop-file-utils}/bin/update-desktop-database \
      ${config.home.homeDirectory}/.local/share/applications
  '';

  home.activation.updateKdeServiceCache = lib.hm.dag.entryAfter [ "updateDesktopDatabase" ] ''
    $DRY_RUN_CMD ${pkgs.kdePackages.kservice}/bin/kbuildsycoca6 --noincremental
  '';
}
