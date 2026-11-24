{
  inputs = {
    # System version
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Import only OpenBao from this independently locked security-update source.
    nixpkgs-openbao.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
    };
    hyprqt6engine = {
      url = "github:hyprwm/hyprqt6engine";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    secrets.url = "git+ssh://git@github.com/SuddenlyBanana/private-nixos";
    nix-gaming-edge.url = "github:powerofthe69/nix-gaming-edge";
    nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      nixpkgs-openbao,
      nixos-hardware,
      home-manager,
      terranix,
      agenix,
      disko,
      lanzaboote,
      zen-browser,
      hyprqt6engine,
      secrets,
      nix-gaming-edge,
      nix-flatpak,
      microvm,
      ...
    }:
    let
      systemLinux = "x86_64-linux";
      openbaoSecurity = (import nixpkgs-openbao { system = systemLinux; }).openbao;
      pkgsLinux = import nixpkgs {
        system = systemLinux;
        # Guests inherit this package set, keeping server, agents and CLI in sync
        # without updating the host/guest NixOS modules or other base packages.
        overlays = [
          (_final: _prev: {
            openbao =
              assert nixpkgs.lib.versionAtLeast openbaoSecurity.version "2.6.5";
              openbaoSecurity;
          })
        ];
        config = {
          allowUnfree = true;
        };
      };

      specialArgs = {
        pkgs-unstable = import nixpkgs-unstable {
          system = systemLinux;
          config.allowUnfree = true;
        };
        inherit
          secrets
          zen-browser
          hyprqt6engine
          nix-gaming-edge
          nix-flatpak
          ;
      };

      hosts = {
        headspace = {
          deployment = {
            targetHost = "headspace.local";
            targetUser = "niko";
            tags = [ "desktop" ];
          };
          modules = [
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = specialArgs;
              };
            }

            ./modules/desktop

            # Hardware configuration
            ./hosts/headspace
            nixos-hardware.nixosModules.apple-macbook-pro-10-1
            # nixos-hardware.nixosModules.common-gpu-nvidia

            # User configuration
            ./users/niko
            home-manager.nixosModules.home-manager
          ];
        };

        hadal-abyss-zone = {
          deployment = {
            # Prefer stable in-band IPv6; .local on br-mgmt remains an OOB fallback.
            targetHost = secrets.privateIps.hadal-abyss-zone.static.v6;
            targetUser = "workspace";
            buildOnTarget = true;
            tags = [ "server" ];
          };
          modules = [
            disko.nixosModules.disko
            lanzaboote.nixosModules.lanzaboote
            microvm.nixosModules.host

            ./modules/server

            # Hardware configuration
            ./hosts/hadal-abyss-zone

            # User configuration
            ./users/workspace
          ];
        };

        float-play = {
          deployment = {
            targetHost = secrets.publicIps.float-play.v6;
            targetUser = "workspace";
            tags = [ "vps" ];
          };
          modules = [
            disko.nixosModules.disko

            ./modules/server

            # Hardware configuration
            ./hosts/float-play

            # User configuration
            ./users/workspace
          ];
        };
      };

      commonModules = [ agenix.nixosModules.default ];
      nixosCommonModules = commonModules ++ [ { nixpkgs.pkgs = pkgsLinux; } ];
    in
    {
      nixosConfigurations = builtins.mapAttrs (
        _: h:
        nixpkgs.lib.nixosSystem {
          inherit specialArgs;
          modules = nixosCommonModules ++ h.modules;
        }
      ) hosts;

      colmena = {
        meta = {
          nixpkgs = pkgsLinux;
          inherit specialArgs;
        };
      }
      // builtins.mapAttrs (_: h: {
        deployment = h.deployment;
        imports = commonModules ++ h.modules;
      }) hosts;

      packages.${systemLinux} = {
        openbao = pkgsLinux.openbao;
        nat64-network-test = import ./hosts/float-play/modules/server/nat64/test.nix { pkgs = pkgsLinux; };
        opnsense-tf = terranix.lib.terranixConfiguration {
          system = systemLinux;
          modules = [ ./hosts/hadal-abyss-zone/vms/opnsense.nix ];
        };

        rocky-firmware-tf = terranix.lib.terranixConfiguration {
          system = systemLinux;
          modules = [ ./hosts/hadal-abyss-zone/vms/rocky-firmware.nix ];
        };

        ubuntu-firmware-tf = terranix.lib.terranixConfiguration {
          system = systemLinux;
          modules = [ ./hosts/hadal-abyss-zone/vms/ubuntu-firmware.nix ];
        };
      };

      checks.${systemLinux} = {
        hadal-network-policy = import ./hosts/hadal-abyss-zone/network-policy/checks.nix {
          pkgs = pkgsLinux;
          configuration = self.nixosConfigurations.hadal-abyss-zone.config;
          inherit secrets;
        };

        hadal-snapshot-safety =
          import ./hosts/hadal-abyss-zone/modules/virt/microvms/backups/checks.nix
            { pkgs = pkgsLinux; };

        openbao-pki = pkgsLinux.runCommand "openbao-pki" {
          nativeBuildInputs = with pkgsLinux; [
            bash
            coreutils
            jq
            openssl
            ripgrep
            openbao
          ];
        } ''
          bash ${./hosts/hadal-abyss-zone/modules/virt/microvms/openbao}/test-pki.sh
          touch "$out"
        '';
      };

      devShells.${systemLinux} = {
        devel = pkgsLinux.mkShell {
          packages = with pkgsLinux; [
            gcc
            gnumake
            cmake
            ninja
            meson
            pkg-config
            gdb
            git
            binutils
            autoconf
            automake
            bison
            flex
            libtool
            patch
            rpm
            strace
            file
            which
            diffutils
            findutils
            curl
            wget
            unzip
            zip
          ];
        };
        devops = pkgsLinux.mkShell {
          packages = [
            agenix.packages.${systemLinux}.default
          ]
          ++ (with pkgsLinux; [
            colmena
            opentofu
            terraform-providers.dmacvicar_libvirt
            wireguard-tools
            fluxcd
            kubectl
            kubernetes-helm
            kustomize
            kubeconform
            openbao
            jq
            openssl
            skopeo
            sqlite
            pgloader
            postgresql_17
            shellcheck
          ]);
        };
      };
    };
}
