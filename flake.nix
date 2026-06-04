{
  inputs = {
    # This is pointing to an unstable release.
    # If you prefer a stable release instead, you can this to the latest number shown here: https://nixos.org/download
    # i.e. nixos-24.11
    # Use `nix flake update` to update the flake to the latest revision of the chosen release channel.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    home-manager.url = "github:nix-community/home-manager/release-25.11";
  };

  outputs = inputs@{ self, nixpkgs, nixpkgs-unstable, nixos-hardware, home-manager, ... }:
    let
      systemLinux = "x86_64-linux";
      pkgsLinux = import nixpkgs {
        system = systemLinux;

	config = {
	  allowUnfree = true;
	  nvidia.acceptLicense = true;
	};
      };
    in { 
      nixosConfigurations.nixbanana = nixpkgs.lib.nixosSystem {
        specialArgs = {
          pkgs-unstable = import nixpkgs-unstable {
	    system = systemLinux;

	    config.allowUnfree = true;
          };
        };

        modules = [
          {
	    nixpkgs.pkgs = pkgsLinux;
	  }

          # Hardware configuration
          ./hosts/nixbanana
          nixos-hardware.nixosModules.apple-macbook-pro-10-1
	  # nixos-hardware.nixosModules.common-gpu-nvidia

	  # System configuration
	  ./modules/desktop

	  # User configuration
          ./users/niko
	  home-manager.nixosModules.home-manager
        ];
      };

      devShells.${systemLinux}.default = pkgsLinux.mkShell {
        packages = with pkgsLinux; [
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

