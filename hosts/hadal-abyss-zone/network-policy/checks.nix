{
  pkgs,
  configuration,
  secrets,
}:

let
  policy = pkgs.writeText "hadal-network-policy.json" (
    builtins.toJSON {
      zones = import ./zones.nix { inherit secrets; };
      topology = import ../modules/virt/microvms/topology.nix { inherit secrets; };
      nat64 = import ../../../modules/server/nat64-topology.nix { inherit secrets; };
      hostAddress = secrets.privateIps.hadal-abyss-zone.static.v6;
      gateway = secrets.privateIps.yurail.v6;
      lanPrefix = secrets.privateIps.subnets.homelabLan;
      floatAddress = secrets.privateIps.float-play.v6;
      tunnelAddress = secrets.privateIps.hadal-abyss-zone.wg-tunnel.v6;
      tables = {
        inherit (configuration.networking.nftables.tables) nixos-fw hadal-zone-boundary;
      };
      routes = configuration.systemd.network.networks."10-br-lan".routes;
      wireguardInterfaces = builtins.attrNames configuration.networking.wireguard.interfaces;
      inputRules = configuration.networking.firewall.extraInputRules;
      forwardRules = configuration.networking.firewall.extraForwardRules;
      backupsEnabled = configuration.hadal.backups.enable;
      snapshotsEnabled = configuration.hadal.backups.onlineSnapshots.enable;
    }
  );
in
pkgs.runCommand "hadal-network-policy-checks"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    python3 -B ${./test.py} --config ${policy}
    mkdir -p "$out"
    cp ${policy} "$out/policy.json"
  ''
