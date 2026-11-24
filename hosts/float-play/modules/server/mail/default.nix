{ lib, pkgs, secrets, ... }:
let
  mail = import ../../../../../modules/server/mail-topology.nix { inherit secrets; };
  rke2Address = "${secrets.privateIps.prefixes.homelabUla}:9::20";
  relayInputRule = "-i wg0 -s ${rke2Address}/128 -d ${mail.relayAddress}/128 -p tcp --dport ${toString mail.relayPort} -j nixos-fw-accept";
in
{
  # Provisioning the private credential opts this host into SMTP2GO delivery.
  imports = lib.optional (secrets.paths ? smtp2go-float-play) ./smtp2go.nix;

  services.nginx.streamConfig = builtins.readFile (pkgs.replaceVars ./nginx-stream.conf.in {
    PUBLIC_V4 = secrets.publicIps.float-play.v4;
    PUBLIC_V6 = secrets.publicIps.float-play.v6;
    PROXY_ADDRESS = mail.relayAddress;
    RKE2_ADDRESS = rke2Address;
  });

  # Stalwart signs mail; this tunnel-only listener queues and sends it from
  # float-play's public addresses. Public TCP 25 belongs to nginx above.
  services.postfix = {
    enable = true;
    settings = {
      main = {
        myhostname = mail.smtpHostname;
        mydomain = mail.smtpHostname;
        myorigin = mail.smtpHostname;
        mydestination = [ ];
        mynetworks = [ "[${rke2Address}]/128" ];
        inet_interfaces = mail.relayAddress;
        inet_protocols = "all";
        smtp_bind_address = secrets.publicIps.float-play.v4;
        smtp_bind_address6 = secrets.publicIps.float-play.v6;
        smtp_address_preference = "ipv4";
        smtp_helo_name = mail.smtpHostname;
        smtpd_client_restrictions = "permit_mynetworks, reject";
        smtpd_relay_restrictions = "permit_mynetworks, reject";
        smtpd_recipient_restrictions = "permit_mynetworks, reject";
        # WireGuard encrypts the hop; STARTTLS is optional for Internet MXs.
        smtpd_tls_security_level = "none";
        smtp_tls_security_level = lib.mkDefault "may";
        disable_vrfy_command = true;
        message_size_limit = 52428800;
      };
      master.smtp_inet.name = lib.mkForce "[${mail.relayAddress}]:${toString mail.relayPort}";
    };
  };
  # The server uses networkd's WireGuard backend, which does not create a
  # wireguard-wg0.service. Wait for the actual IPv6 listener address instead.
  systemd.services.postfix-network-ready = {
    description = "Wait for the Postfix WireGuard listener network";
    requires = [ "systemd-networkd.service" ];
    after = [ "systemd-networkd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-networkd-wait-online --interface=wg0:routable --ipv6 --timeout=60";
    };
  };
  systemd.services.postfix = {
    requires = [ "postfix-network-ready.service" ];
    after = [ "postfix-network-ready.service" ];
  };
  networking.firewall = {
    allowedTCPPorts = [ 25 465 993 ];
    # Jool requires this host's iptables backend; nftables-only extraInputRules
    # would be ignored. Keep the relay private and restricted to the node ULA.
    extraCommands = "${pkgs.iptables}/bin/ip6tables -w -I nixos-fw 1 ${relayInputRule}";
    extraStopCommands = "${pkgs.iptables}/bin/ip6tables -w -D nixos-fw ${relayInputRule} 2>/dev/null || true";
  };
}
