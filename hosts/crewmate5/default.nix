{
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./disk-config.nix
    ./hardware-configuration.nix
    ../../modules/base.nix
    ../../modules/auto-upgrade.nix
    ../../modules/tailscale.nix
    ../../services/receipt-printer
  ];

  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  networking.hostName = "crewmate5";

  time.timeZone = "America/New_York";

  system.stateVersion = "26.05";
}
