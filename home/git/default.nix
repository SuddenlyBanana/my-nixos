{ ... }:

{
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "SuddenlyBanana";
        email = "SuddenlyBanana@proton.me";
      };

      init.defaultBranch = "main";
    };
  };
}
