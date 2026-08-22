{ ... }:

{
  xdg = {
    enable = true;
    mime.enable = true;
    mimeApps = {
      enable = true;
      defaultApplications = {
        "inode/directory" = "org.kde.dolphin.desktop";

        "text/html" = "zen-twilight.desktop";
        "application/xhtml+xml" = "zen-twilight.desktop";
        "x-scheme-handler/http" = "zen-twilight.desktop";
        "x-scheme-handler/https" = "zen-twilight.desktop";

        "application/zip" = "org.kde.ark.desktop";
        "application/x-7z-compressed" = "org.kde.ark.desktop";
        "application/x-bzip2" = "org.kde.ark.desktop";
        "application/x-rar" = "org.kde.ark.desktop";
        "application/x-tar" = "org.kde.ark.desktop";
        "application/x-xz" = "org.kde.ark.desktop";
      };
    };
  };
}
