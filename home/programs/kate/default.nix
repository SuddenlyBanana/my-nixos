{ pkgs, ... }:

{
  # Kate ships KSyntaxHighlighting definitions and its LSP client.  Servers on
  # PATH are detected automatically for the corresponding file type.
  home.packages = with pkgs; [
    kdePackages.kate
    nixd
    nixfmt
    clang-tools
    lua-language-server
    rust-analyzer
    pyright
    typescript-language-server
    yaml-language-server
    vscode-langservers-extracted
  ];

  home.file.".config/kate/lspclient/settings.json".source = ./settings.json;
}
