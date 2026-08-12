{ pkgs, ... }:

{
  home.packages = with pkgs; [
    clang
    nixd
    nixfmt
    prettier
    stylua
  ];

  programs.vscode = {
    enable = true;
    package = pkgs.vscode;

    # Keep the extension directory mutable. This permits VS Code Settings Sync
    # to restore marketplace extensions which are not packaged in nixpkgs.
    profiles.default = {
      enableExtensionUpdateCheck = false;
      enableUpdateCheck = false;
      userSettings = builtins.fromJSON (builtins.readFile ./settings.json);
    };
  };
}
