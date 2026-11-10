{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:

let
  cfg = config.hadal.bootstrap;
  stage = pkgs.writeShellApplication {
    name = "stage-hadal-bootstrap";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./scripts/stage-bootstrap.sh;
  };
  names = [
    "vm-storage-key"
    "media-storage-key"
    "ca-cert"
    "openbao-recovery-cert"
    "openbao-recovery-key"
    "openbao-role-id"
    "openbao-secret-id"
    "postgresql-role-id"
    "postgresql-secret-id"
    "rke2-token"
    "flux-ssh-key"
    "flux-known-hosts"
    "pgbackrest-pass"
    "restic-password"
    "backup-role-id"
    "backup-secret-id"
  ];
in
{
  options.hadal.bootstrap.encryptedFiles = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = secrets.hadalBootstrap or { };
    description = "Bootstrap ciphertext paths exported as hadalBootstrap by the private secrets flake.";
  };

  config = {
    warnings = lib.optional (cfg.encryptedFiles == { })
      "Hadal bootstrap ciphertexts are not configured: export secrets.hadalBootstrap in private-nixos before deployment. Evaluation alone does not prove guest bootstrap readiness.";
    assertions = [
      {
        assertion = lib.all (name: builtins.elem name names) (builtins.attrNames cfg.encryptedFiles);
        message = "Unknown hadal.bootstrap.encryptedFiles entry.";
      }
    ];
    age.secrets = lib.mapAttrs' (
      name: file:
      lib.nameValuePair "hadal-bootstrap-${name}" {
        inherit file;
        mode = "0400";
        owner = "root";
      }
    ) cfg.encryptedFiles;

    systemd.services =
      lib.genAttrs
        (map (name: "hadal-bootstrap-${name}") [
          "openbao"
          "postgresql"
          "rke2"
        ])
        (
          unit:
          let
            name = lib.removePrefix "hadal-bootstrap-" unit;
          in
          {
            description = "Stage agenix bootstrap files for ${name}";
            after = [ "agenix-install-secrets.service" ];
            before = [
              "microvm-virtiofsd@${name}.service"
              "microvm@${name}.service"
            ];
            restartTriggers = builtins.attrValues cfg.encryptedFiles;
            environment.BOOTSTRAP_VM = name;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              UMask = "0077";
              ExecStart = lib.getExe stage;
            };
          }
        )
      //
        lib.genAttrs
          (map (name: "microvm-virtiofsd@${name}") [
            "openbao"
            "postgresql"
            "rke2"
          ])
          (
            unit:
            let
              name = lib.removePrefix "microvm-virtiofsd@" unit;
            in
            {
              requires = [ "hadal-bootstrap-${name}.service" ];
              after = [ "hadal-bootstrap-${name}.service" ];
            }
          );
  };
}
