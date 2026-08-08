{ ... }:

{
  programs.zen-browser = {
    enable = true;

    profiles.default = {
      id = 0;
      isDefault = true;
      settings = {
        "browser.contentblocking.category" = "custom";
        "browser.download.useDownloadDir" = false;
        "browser.tabs.warnOnClose" = true;
        "browser.urlbar.quicksuggest.scenario" = "history";
        "network.dns.disablePrefetch" = true;
        "network.http.speculative-parallel-limit" = 0;
        "network.prefetch-next" = false;
        "privacy.donottrackheader.enabled" = true;
        "privacy.fingerprintingProtection" = true;
        "privacy.trackingprotection.emailtracking.enabled" = true;
        "privacy.trackingprotection.enabled" = true;
        "privacy.trackingprotection.socialtracking.enabled" = true;
        "zen.theme.accent-color" = "#d4bbff";
        "zen.view.compact.enable-at-startup" = true;
        "zen.view.show-newtab-button-border-top" = true;
        "zen.view.use-single-toolbar" = false;
        "zen.view.window.scheme" = 0;
        "zen.workspaces.continue-where-left-off" = true;
      };
    };
  };

  # UI-only Zen profile data. Browser history, sessions, cookies, saved
  # passwords, extension storage, and bookmarks are deliberately excluded.
  home.file = {
    ".zen/default/zen-keyboard-shortcuts.json".source = ./config/zen-keyboard-shortcuts.json;
    ".zen/default/zen-themes.json".source = ./config/zen-themes.json;
  };
}
