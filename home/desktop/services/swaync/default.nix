{ ... }:

{
  services.swaync = {
    enable = true;
    settings = {
      ignore-gtk-theme = true;
      cssPriority = "user";
    };
  };
}
