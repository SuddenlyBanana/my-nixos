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
      inputs.nixpkgs.follows = "nixpkgs";
    };
    tuigreet = {
      url = "github:NotAShelf/tuigreet";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hyprqt6engine = {
      url = "github:hyprwm/hyprqt6engine";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    secrets.url = "git+ssh://git@github.com/SuddenlyBanana/private-nixos";
  };

  outputs = { nixpkgs, nixpkgs-unstable, nixos-hardware, home-manager, terranix
    , agenix, disko, lanzaboote, zen-browser, tuigreet, hyprqt6engine, secrets, ... }:
    let
      systemLinux = "x86_64-linux";
      systemDarwin = "x86_64-darwin";
      systems = [ systemLinux systemDarwin ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsLinux = import nixpkgs {
        system = systemLinux;
        config.allowUnfree = true;
      };

      pkgsDarwin = import nixpkgs {
        system = systemDarwin;
        config.allowUnfree = true;
      };

      specialArgs = {
        pkgs-unstable = import nixpkgs-unstable {
          system = systemLinux;
          config.allowUnfree = true;
        };
        inherit secrets zen-browser tuigreet hyprqt6engine;
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
            targetHost = "hadal-abyss-zone.local";
            targetUser = "workspace";
            buildOnTarget = true;
            tags = [ "server" ];
          };
          modules = [
            disko.nixosModules.disko
            lanzaboote.nixosModules.lanzaboote

            # Hardware configuration
            ./hosts/hadal-abyss-zone

            # User configuration
            ./users/workspace
          ];
        };

        relayouter = {
          deployment = {
            targetHost = secrets.publicIps.relayouter.v6;
            targetUser = "workspace";
            tags = [ "vps" ];
          };
          modules = [
            disko.nixosModules.disko

            # Hardware configuration
            ./hosts/relayouter

            # User configuration
            ./users/workspace
          ];
        };
      };

      commonModules = [ agenix.nixosModules.default ];
      nixosCommonModules = commonModules ++ [{ nixpkgs.pkgs = pkgsLinux; }];
    in {
      nixosConfigurations = builtins.mapAttrs (_: h:
        nixpkgs.lib.nixosSystem {
          inherit specialArgs;
          modules = nixosCommonModules ++ h.modules;
        }) hosts;

      colmena = {
        meta = {
          nixpkgs = pkgsLinux;
          inherit specialArgs;
        };
      } // builtins.mapAttrs (_: h: {
        deployment = h.deployment;
        imports = commonModules ++ h.modules;
      }) hosts;

      packages = forAllSystems (system: {
        opnsense-tf = terranix.lib.terranixConfiguration {
          inherit system;
          modules = [ ./hosts/hadal-abyss-zone/vms/opnsense.nix ];
        };

        rocky-firmware-tf = terranix.lib.terranixConfiguration {
          inherit system;
          modules = [ ./hosts/hadal-abyss-zone/vms/rocky-firmware.nix ];
        };

        ubuntu-firmware-tf = terranix.lib.terranixConfiguration {
          inherit system;
          modules = [ ./hosts/hadal-abyss-zone/vms/ubuntu-firmware.nix ];
        };
      });

      devShells.${systemLinux}.default = pkgsLinux.mkShell {
        packages = with pkgsLinux; [
          colmena
          opentofu
          terraform-providers.dmacvicar_libvirt
          wireguard-tools
          gcc
          gnumake
          cmake
          pkg-config
          gdb
          git
          binutils
          autoconf
          automake
          libtool
        ];
      };

      devShells.${systemDarwin}.default = pkgsDarwin.mkShell {
        packages = with pkgsDarwin; [
          colmena
          opentofu
          terraform-providers.dmacvicar_libvirt
          wireguard-tools
          gcc
          gnumake
          cmake
          pkg-config
          gdb
          git
          binutils
          autoconf
          automake
          libtool
        ];
      };
    };
}
