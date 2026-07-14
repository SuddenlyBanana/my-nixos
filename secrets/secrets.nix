let
  # User keys — anyone with these can edit secrets via `agenix -e`.
  users = {
    banana =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIijmUFfAZbhbcFMnWSFyM0NEUviWiVEvCO1qB/jra+/ SuddenlyBanana@proton.me";
    teto =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKPQ80PQ7ZhPmQm9PJ4DLebxsVX8WvChA61twLuzYbH3 teto";
  };

  # Host keys — agenix decrypts at boot using /etc/ssh/ssh_host_ed25519_key.
  # Add each host after first boot:
  #   ssh <host> 'cat /etc/ssh/ssh_host_ed25519_key.pub'
  # then rerun `agenix -r` (re-encrypts all secrets to the new recipient list).
  hosts = {
    # relayouter = "ssh-ed25519 AAAA...";
    # hadal-abyss-zone = "ssh-ed25519 AAAA...";
  };

  allUsers = builtins.attrValues users;
  keyFor = host: allUsers ++ (if hosts ? ${host} then [ hosts.${host} ] else [ ]);
in {
  "wg0-relayouter.age".publicKeys = keyFor "relayouter";
  "wg0-hadal-abyss-zone.age".publicKeys = keyFor "hadal-abyss-zone";
}
