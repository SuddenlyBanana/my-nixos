{ ... }:

{
  programs.wofi = {
    enable = true;
    settings = {
      width = 600;
      height = 400;
      prompt = "Search";
      insensitive = true;
    };
  };
}
