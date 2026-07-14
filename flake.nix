{
  inputs = {
    # System version
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-generators.url = "github:nix-community/nixos-generators";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, home-manager
    , terranix, nixos-generators, agenix, ... }:
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
      };

      hosts = {
        nixbanana = {
          deployment = {
            targetHost = "nixbanana.local";
            targetUser = "niko";
            tags = [ "desktop" ];
          };
          modules = [
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
              };
            }

            # Hardware configuration
            ./hosts/nixbanana
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
            tags = [ "server" ];
          };
          modules = [
            # Hardware configuration
            ./hosts/hadal-abyss-zone

            # User configuration
            ./users/workspace
          ];
        };

        relayouter = {
          deployment = {
            targetHost = "relayouter";
            targetUser = "workspace";
            tags = [ "vps" ];
          };
          modules = [
            # Hardware configuration
            ./hosts/relayouter

            # User configuration
            ./users/workspace
          ];
        };
      };

      commonModules =
        [ { nixpkgs.pkgs = pkgsLinux; } agenix.nixosModules.default ];
    in {
      nixosConfigurations = builtins.mapAttrs (_: h:
        nixpkgs.lib.nixosSystem {
          inherit specialArgs;
          modules = commonModules ++ h.modules;
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
        x86_64-linux.do = nixos-generators.nixosGenerate {
          system = systemLinux;
          modules = commonModules ++ [ ./hosts/relayouter ./users/workspace ];
          format = "do";
        };
      });

      devShells.${systemLinux}.default = pkgsLinux.mkShell {
        packages = with pkgsLinux; [
          colmena
          opentofu
          terraform-providers.dmacvicar_libvirt
          agenix.packages.${systemLinux}.default
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
          agenix.packages.${systemDarwin}.default
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

