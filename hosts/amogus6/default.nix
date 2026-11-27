# Hetzner Cloud CX (x86, fsn1), replacing imposter4
{
  config,
  modulesPath,
  pkgs,
  ...
}:
let
  storageBoxKey = "/var/lib/secrets/storagebox_ed25519";
in
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
    ../../services/seafile
  ];

  # Hetzner Storage Box sub-account over SFTP with an SSH key, for Seafile's file
  # blocks. No passwords: the client refuses anything but the key, and only
  # Hetzner's pinned host key is trusted. The key is root-only, so the seafile
  # user can use the mounted files but never the Storage Box account itself.
  # Only the box's `seafile` folder is mounted, so .ssh/authorized_keys stays out
  # of reach. One-time setup, as root on the server, after the first deploy:
  #   cat /var/lib/secrets/storagebox_ed25519.pub \
  #     | ssh -p23 u731385-sub2@u731385-sub2.your-storagebox.de install-ssh-key
  #   echo 'mkdir seafile' | sftp -P23 -i /var/lib/secrets/storagebox_ed25519 \
  #     u731385-sub2@u731385-sub2.your-storagebox.de
  #   systemctl restart mnt-storagebox.mount && systemctl start podman-seafile
  # install-ssh-key asks for the sub-account password once; reset it to a long
  # random one afterwards and don't keep it (Hetzner can't turn passwords off).
  fileSystems."/mnt/storagebox" = {
    device = "u731385-sub2@u731385-sub2.your-storagebox.de:seafile";
    fsType = "sshfs";
    options = [
      "port=23"
      "ssh_command=${pkgs.openssh}/bin/ssh"
      "IdentityFile=${storageBoxKey}"
      "IdentitiesOnly=yes"
      "PreferredAuthentications=publickey"
      "PasswordAuthentication=no"
      "KbdInteractiveAuthentication=no"
      "BatchMode=yes"
      # only the host key pinned in programs.ssh.knownHosts below
      "StrictHostKeyChecking=yes"
      "UserKnownHostsFile=/dev/null"
      "HostKeyAlgorithms=ssh-ed25519"
      "reconnect"
      "ServerAliveInterval=15"
      "ServerAliveCountMax=3"
      # everything on it belongs to the rootless seafile user, and only to it
      "allow_other"
      "default_permissions"
      "uid=${toString config.users.users.seafile.uid}"
      "gid=${toString config.users.groups.seafile.gid}"
      "umask=077"
      "noexec"
      "nosuid"
      "nodev"
      # don't hold up boot if the box is unreachable; services needing it wait instead
      "_netdev"
      "nofail"
      "x-systemd.after=network-online.target"
      "x-systemd.wants=network-online.target"
      "x-systemd.requires=storagebox-key.service"
      "x-systemd.after=storagebox-key.service"
    ];
  };

  # Hetzner's published Storage Box host key (SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM)
  programs.ssh.knownHosts.storagebox = {
    hostNames = [ "[u731385-sub2.your-storagebox.de]:23" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICf9svRenC/PLKIL9nk6K/pxQgoiFC41wTNvoIncOxs";
  };

  # The repo is public, so the key is generated on the server once
  systemd.services.storagebox-key = {
    description = "Generate the Storage Box SSH key";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -f ${storageBoxKey} ]; then
        install -d -m 700 "$(dirname ${storageBoxKey})"
        ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "amogus6 seafile" -f ${storageBoxKey}
      fi
    '';
  };

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
