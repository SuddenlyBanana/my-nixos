{
  inputs = {
    # System version
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
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
    wapmail = {
      url = "git+ssh://git@github.com/SuddenlyBanana/WAPmail";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
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
      wapmail,
      ...
    }:
    let
      systemLinux-x86_64 = "x86_64-linux";
      systemLinux-aarch64 = "aarch64-linux";
      forAllSystems = [
        systemLinux-x86_64
        systemLinux-aarch64
      ];

      specialArgs = {
        inherit
          secrets
          zen-browser
          hyprqt6engine
          nix-gaming-edge
          nix-flatpak
          wapmail
          ;
      };

      hosts = {
        headspace = {
          system = systemLinux-x86_64;
          overlays = [ nix-gaming-edge.overlays.default ];
          deployment = {
            targetHost = "headspace.local";
            targetUser = "niko";
            tags = [ "desktop" ];
          };
          modules = [
            ({ pkgs-unstable, ... }: {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = specialArgs // {
                  inherit pkgs-unstable;
                };
              };
            })

            ./modules/desktop

            # Hardware configuration
            ./hosts/headspace
            nixos-hardware.nixosModules.apple-macbook-pro-10-1
            # nixos-hardware.nixosModules.common-gpu-nvidia
            nix-gaming-edge.nixosModules.default

            # User configuration
            ./users/niko
            home-manager.nixosModules.home-manager
          ];
        };

        hadal-abyss-zone = {
          system = systemLinux-x86_64;
          deployment = {
            targetHost = "hadal-abyss-zone.local";
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
          system = systemLinux-x86_64;
          deployment = {
            targetHost = secrets.publicIps.float-play.v6;
            targetUser = "workspace";
            tags = [
              "server"
              "vps"
            ];
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

        ipace = {
          system = systemLinux-aarch64;
          deployment = {
            targetHost = "ipace.local";
            targetUser = "workspace";
            buildOnTarget = true;
            tags = [
              "server"
              "raspberry-pi"
            ];
          };
          modules = [
            nixos-hardware.nixosModules.raspberry-pi-5

            ./modules/server

            ./hosts/ipace

            ./users/workspace
          ];
        };
      };

      commonModules = [ agenix.nixosModules.default ];
      hostPkgs =
        h:
        import nixpkgs {
          system = h.system;
          overlays = h.overlays or [ ];
          config = {
            allowUnfree = true;
            permittedInsecurePackages = [
              "broadcom-sta-6.30.223.271-59-7.3.3"
            ];
          };
        };
      hostSpecialArgs =
        h:
        specialArgs
        // {
          pkgs-unstable = import nixpkgs-unstable {
            system = h.system;
            config = {
              allowUnfree = true;
              permittedInsecurePackages = [ "python3.14-pybars3-0.9.7" ];
            };
          };
        };

      ipaceCross = nixpkgs.lib.nixosSystem {
        specialArgs = hostSpecialArgs hosts.ipace;
        modules =
          commonModules
          ++ hosts.ipace.modules
          ++ [
            {
              nixpkgs.pkgs = import nixpkgs {
                localSystem = systemLinux-x86_64;
                crossSystem = systemLinux-aarch64;
                config.allowUnfree = true;
                overlays = [ (import ./hosts/ipace/cross-overlay.nix) ];
              };
            }
          ];
      };
    in
    {
      nixosConfigurations = builtins.mapAttrs (
        _: h:
        nixpkgs.lib.nixosSystem {
          specialArgs = hostSpecialArgs h;
          modules = commonModules ++ [ { nixpkgs.pkgs = hostPkgs h; } ] ++ h.modules;
        }
      ) hosts;

      colmena = {
        meta = {
          nixpkgs = hostPkgs { system = systemLinux-x86_64; };
          inherit specialArgs;
          nodeNixpkgs = builtins.mapAttrs (_: h: hostPkgs h) hosts;
          nodeSpecialArgs = builtins.mapAttrs (_: h: hostSpecialArgs h) hosts;
        };
      }
      // builtins.mapAttrs (_: h: {
        deployment = h.deployment;
        imports = commonModules ++ h.modules;
      }) hosts;

      packages.${systemLinux-x86_64} = {
        ipace-sd-image = ipaceCross.config.system.build.sdImage;

        opnsense-tf = terranix.lib.terranixConfiguration {
          inherit systemLinux-x86_64;
          modules = [ ./hosts/hadal-abyss-zone/vms/opnsense.nix ];
        };

        rocky-firmware-tf = terranix.lib.terranixConfiguration {
          inherit systemLinux-x86_64;
          modules = [ ./hosts/hadal-abyss-zone/vms/rocky-firmware.nix ];
        };

        ubuntu-firmware-tf = terranix.lib.terranixConfiguration {
          inherit systemLinux-x86_64;
          modules = [ ./hosts/hadal-abyss-zone/vms/ubuntu-firmware.nix ];
        };
      };

      packages.${systemLinux-aarch64}.ipace-sd-image =
        self.nixosConfigurations.ipace.config.system.build.sdImage;

      devShells = nixpkgs.lib.genAttrs forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        {
          devel = pkgs.mkShell {
            packages = with pkgs; [
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
          devops = pkgs.mkShell {
            packages = with pkgs; [
              colmena
              opentofu
              agenix.packages.x86_64-linux.default
              terraform-providers.dmacvicar_libvirt
              wireguard-tools
            ];
          };
        }
      );
    };
}
