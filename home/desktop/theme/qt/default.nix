{ ... }:

{
  qt = {
    enable = true;
    platformTheme.name = "qtct";
    style.name = "kvantum";

    qt5ctSettings = {
      Appearance = {
        style = "kvantum";
        icon_theme = "Papirus-Dark";
        standard_dialogs = "xdgdesktopportal";
      };
      Fonts = {
        general = "\"JetBrainsMono Nerd Font,10\"";
        fixed = "\"JetBrainsMono Nerd Font Mono,10\"";
      };
    };

    qt6ctSettings = {
      Appearance = {
        style = "kvantum";
        icon_theme = "Papirus-Dark";
        standard_dialogs = "xdgdesktopportal";
      };
      Fonts = {
        general = "\"JetBrainsMono Nerd Font,10\"";
        fixed = "\"JetBrainsMono Nerd Font Mono,10\"";
      };
    };
  };
}
