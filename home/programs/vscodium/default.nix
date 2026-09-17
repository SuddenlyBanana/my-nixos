{ pkgs, ... }:

{
  programs.vscodium = {
    enable = true;
    package = pkgs.vscodium-fhs;
    profiles.default = {
      extensions = with pkgs.vscode-extensions; [
        # HTML and CSS
        ecmel.vscode-html-css
        formulahendry.auto-rename-tag
        stylelint.vscode-stylelint

        # JavaScript and shared web formatting
        dbaeumer.vscode-eslint
        esbenp.prettier-vscode

        # PHP
        bmewburn.vscode-intelephense-client
        xdebug.php-debug

        # Local HTML/CSS/JavaScript/PHP preview server
        ritwickdey.liveserver
      ];
    };
  };
}
