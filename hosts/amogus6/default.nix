# Hetzner Cloud CX (x86, fsn1), replacing imposter4
{
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disk-config.nix
    ./hardware-configuration.nix
    ../../modules/base.nix
    ../../modules/caddy.nix
    ../../modules/auto-upgrade.nix
    ../../modules/tailscale.nix
    ../../services/forgejo
    ../../services/github-mirror
    ../../services/searxng
  ];

  boot.loader.grub = {
    # disko adds every disk with an EF02 partition to grub.devices. Hetzner Cloud
    # x86 boots BIOS; the removable EFI install is there in case that changes.
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  # Lets the hypervisor see the IP, freeze filesystems for snapshots, and shut down cleanly
  services.qemuGuest.enable = true;

  networking.hostName = "amogus6";

  # Hetzner Cloud hands out IPv4 over DHCP, but the IPv6 /64 has to be set statically
  networking.useNetworkd = true;
  systemd.network.networks."10-wan" = {
    matchConfig.MACAddress = "92:00:0a:99:dd:61";
    networkConfig.DHCP = "ipv4";
    address = [ "2a01:4f8:c17:4066::1/64" ];
    routes = [ { Gateway = "fe80::1"; } ];
  };

  time.timeZone = "America/New_York";

  system.stateVersion = "26.11";
}
