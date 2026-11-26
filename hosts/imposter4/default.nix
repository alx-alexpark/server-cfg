{
  modulesPath,
  ...
} @ args:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disk-config.nix
    ./hardware-configuration.nix
    # Kept bare until the contract runs out; its services moved to amogus6.
    # Still a Tailscale exit node, so traffic can leave from a second location.
    ../../modules/base.nix
    ../../modules/auto-upgrade.nix
    ../../modules/tailscale.nix
  ];

  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # Lets the hypervisor see the IP, freeze filesystems for snapshots, and shut down cleanly
  services.qemuGuest.enable = true;

  networking.hostName = "imposter4";

  time.timeZone = "America/New_York";

  system.stateVersion = "24.05";
}
