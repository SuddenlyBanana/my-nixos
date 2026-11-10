{ pkgs }:

pkgs.testers.runNixOSTest {
  name = "hadal-scoped-nat64";
  nodes = {
    router = { ... }: {
      virtualisation.memorySize = 384;
      virtualisation.cores = 1;
      imports = [ ./default.nix ];
      _module.args.secrets = {
        publicIps.float-play.v4 = "203.0.113.1";
        privateIps = {
          prefixes.homelabUla = "fd00:1234";
          subnets.homelabLan = "fd00:1234:10::/64";
          hadal-abyss-zone = {
            wg-tunnel.v6 = "fd00:1234::2";
            subnets.serviceLan = "fd00:1234:9::/64";
          };
        };
      };
      virtualisation.vlans = [
        1
        2
      ];
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv6.addresses = [
        {
          address = "fd00:1234:9::1";
          prefixLength = 64;
        }
      ];
      networking.interfaces.eth2 = {
        ipv4.addresses = [
          {
            address = "203.0.113.1";
            prefixLength = 24;
          }
        ];
        ipv6.addresses = [
          {
            address = "fd00:bad::1";
            prefixLength = 64;
          }
        ];
      };
    };
    client = { ... }: {
      virtualisation.memorySize = 384;
      virtualisation.cores = 1;
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv6.addresses = [
        {
          address = "fd00:1234:9::2";
          prefixLength = 64;
        }
      ];
      networking.defaultGateway6 = {
        address = "fd00:1234:9::1";
        interface = "eth1";
      };
    };
    server = { ... }: {
      virtualisation.memorySize = 384;
      virtualisation.cores = 1;
      virtualisation.vlans = [ 2 ];
      networking.useDHCP = false;
      networking.interfaces.eth1 = {
        ipv4.addresses = [
          {
            address = "203.0.113.16";
            prefixLength = 24;
          }
        ];
        ipv6.addresses = [
          {
            address = "fd00:bad::2";
            prefixLength = 64;
          }
        ];
      };
      networking.defaultGateway6 = {
        address = "fd00:bad::1";
        interface = "eth1";
      };
      services.nginx = {
        enable = true;
        virtualHosts.default.locations."/".return = "200 'NAT64 test passed'";
      };
      networking.firewall.allowedTCPPorts = [ 80 ];
    };
  };
  testScript = builtins.readFile ./test.py;
}
