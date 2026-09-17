{ ... }:

{
  security.apparmor = {
    enable = true;

    # DNS is needed for the LAN. Collect policy misses before enforcing these.
    policies = {
      hadal-unbound = {
        path = ./unbound.profile;
        state = "complain";
      };

      hadal-knot = {
        path = ./knot.profile;
        state = "complain";
      };
    };
  };
}
