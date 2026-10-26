{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./disk-config.nix
    ../../modules/base.nix
    ../../modules/auto-upgrade.nix
  ];

  # No hardware-configuration.nix: the stick boots on whatever PC it's plugged into,
  # so load drivers for the common USB, SATA, NVMe and SD controllers and keyboards
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ehci_pci"
    "ohci_pci"
    "uhci_hcd"
    "usb_storage"
    "uas"
    "ahci"
    "nvme"
    "sd_mod"
    "sr_mod"
    "sdhci_pci"
    "rtsx_pci_sdmmc"
    "usbhid"
    "hid_generic"
  ];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];

  nixpkgs.hostPlatform = "x86_64-linux";
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;
  hardware.cpu.amd.updateMicrocode = true;

  boot.loader.grub = {
    # UEFI only: GRUB writes just to the stick's own ESP, never to a whole disk
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # Keep writes to the stick down
  boot.tmp.useTmpfs = true;
  zramSwap.enable = true;
  services.journald.settings.Journal.SystemMaxUse = "100M";

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;
  hardware.graphics.enable = true;
  hardware.bluetooth.enable = true;
  networking.networkmanager = {
    enable = true;
    # new random MAC per network, and don't announce the hostname over DHCP
    wifi.macAddress = "random";
    ethernet.macAddress = "random";
    settings.connection = {
      "ipv4.dhcp-send-hostname" = false;
      "ipv6.dhcp-send-hostname" = false;
    };
  };

  # Proton VPN's WireGuard connections fail the strict reverse-path check
  networking.firewall.checkReversePath = "loose";

  environment.systemPackages = [
    pkgs.proton-vpn
    pkgs.librewolf
    pkgs.tor-browser
    pkgs.keepassxc
    # strips metadata from photos, PDFs and documents before sharing
    pkgs.metadata-cleaner
  ];

  # base.nix locks alex's password (SSH-only); GNOME needs one to log in
  # Same as the shared root password, in 1Password as "imposter4 root"
  users.users.alex = {
    hashedPassword = lib.mkForce config.users.users.root.hashedPassword;
    extraGroups = [ "networkmanager" ];
  };

  networking.hostName = "usb-boot";

  time.timeZone = "America/New_York";

  system.stateVersion = "26.05";
}
