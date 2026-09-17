{ pkgs, ... }:

let
  phpCsFixer = pkgs.php84Packages.php-cs-fixer;
in
{
  # Kate ships KSyntaxHighlighting definitions and its LSP client.  Servers on
  # PATH are detected automatically for the corresponding file type.
  home.packages = with pkgs; [
    kdePackages.kate
    nixd
    nixfmt
    clang-tools
    gopls
    lemminx
    lua-language-server
    rust-analyzer
    pyright
    phpactor
    phpCsFixer
    typescript-language-server
    yaml-language-server
    vscode-langservers-extracted
  ];

  home.file.".config/kate/lspclient/settings.json".source = ./settings.json;

  # Phpactor's formatter is backed by PHP CS Fixer.  Point it at the Nix store
  # package so it works even when a project does not vendor the fixer.
  home.file.".config/phpactor/phpactor.json".text = builtins.toJSON {
    "language_server_php_cs_fixer.enabled" = true;
    "language_server_php_cs_fixer.bin" = "${phpCsFixer}/bin/php-cs-fixer";
  };
}
