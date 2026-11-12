{ pkgs-unstable, ... }:

{
  programs.codex = {
    enable = true;
    package = pkgs-unstable.codex.overrideAttrs (previous: {
      buildInputs = previous.buildInputs ++ [
        pkgs-unstable.aws-lc
        pkgs-unstable.oniguruma
        pkgs-unstable.zstd
        pkgs-unstable.sqlite
      ];

      preBuild = (previous.preBuild or "") + ''
        export NIX_BUILD_CORES=$((NIX_BUILD_CORES > 2 ? 2 : NIX_BUILD_CORES))
      '';
    });
    enableMcpIntegration = true;
  };
}
