{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.disko.url = "github:nix-community/disko";
  inputs.disko.inputs.nixpkgs.follows = "nixpkgs";
  inputs.nixos-facter-modules.url = "github:numtide/nixos-facter-modules";
  inputs.receipt-printer = {
    url = "github:alx-alexpark/receipt-printer";
    flake = false;
  };

  outputs =
    {
      nixpkgs,
      disko,
      nixos-facter-modules,
      receipt-printer,
      ...
    }:
    {
      # Use this for all other targets
      # nixos-anywhere --flake .#generic --generate-hardware-config nixos-generate-config ./hardware-configuration.nix <hostname>
      nixosConfigurations.imposter4 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          ./hosts/imposter4
        ];
      };

      nixosConfigurations.crewmate5 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit receipt-printer; };
        modules = [
          disko.nixosModules.disko
          ./hosts/crewmate5
        ];
      };

      # Install from a NixOS live ISO with the stick plugged in:
      # nix run github:nix-community/disko/latest#disko-install -- --flake github:alx-alexpark/server-cfg#usb-boot --disk main /dev/sdX
      nixosConfigurations.usb-boot = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          ./hosts/usb-boot
        ];
      };
    };
}
