{ config, pkgs, secrets, ... }:
let
  endpoint = "[mail.smtp2go.com]:587";
  credential = config.age.secrets.postfix-smtp2go;
in
{
  age.secrets.postfix-smtp2go = {
    file = secrets.paths.smtp2go-float-play;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  services.postfix.settings.main = {
    relayhost = [ endpoint ];
    smtp_sasl_auth_enable = true;
    # Keep the password out of generated main.cf and the Nix store. Postfix
    # reads the root-only map directly; no plaintext database copy is needed.
    smtp_sasl_password_maps = "texthash:${credential.path}";
    smtp_sasl_security_options = "noanonymous, noplaintext";
    smtp_sasl_tls_security_options = "noanonymous";
    smtp_tls_security_level = "secure";
    smtp_tls_secure_cert_match = "nexthop";
    smtp_tls_servername = "mail.smtp2go.com";
    smtp_tls_mandatory_protocols = ">=TLSv1.2";
  };

  systemd.services.postfix = {
    # texthash maps stay cached in SMTP processes; restart on secret rotation.
    restartTriggers = [ credential.file ];
    serviceConfig.ExecStartPre = "${pkgs.coreutils}/bin/test -s ${credential.path}";
  };
}
