{ ... }:

{
  programs.fish = {
    enable = true;
    shellAliases = {
      nxr = "sudo nixos-rebuild switch";
    };
  };
}
