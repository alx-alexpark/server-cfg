{
  config,
  lib,
  pkgs,
  ...
} @ args:
let
  sshKeys = [
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIAKWfF9y67GxL3jIFcQfWvTOBOyIPtreimhYpxTHJ3CcAAAABHNzaDo= a@susbook.local"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAINlmapiWuvpREQGuJJBP/Pv2N3Tt9zIhXIkcAlFt0ZsnAAAABHNzaDo= a@susbook.local"
  ] ++ (args.extraPublicKeys or []); # this is used for unit-testing this module and can be removed if not needed
in
{
  # Users and passwords come only from this config; SSH keys are the only way in
  users.mutableUsers = false;

    # Console-only fallback (sshd rejects passwords); plaintext is in 1Password as "imposter4 root" (shared by all hosts)
  users.users.root = {
    hashedPassword = "$y$j9T$XIWnwSqIsWgVpPckLU8H71$pI79G2WvI9egP73VAcHWoUq8dCReNNPLYsWHEbIfkUD";
    openssh.authorizedKeys.keys = sshKeys;
  };

  users.users.alex = {
    isNormalUser = true;
    hashedPassword = "!";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = sshKeys;
  };

  # alex has no password; login is SSH-only with hardware-backed keys
  security.sudo = {
    wheelNeedsPassword = false;
    execWheelOnly = true;
  };

  security.pki.caCertificateBlacklist = [
    "Comodo AAA Services root"
    "emSign ECC Root CA - G3"
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;

  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };

  environment.systemPackages = map lib.lowPrio [
    pkgs.curl
    pkgs.gitMinimal
  ] ++ [
    # `rebuild`: switch to the latest config on GitHub now, instead of waiting for autoUpgrade
    (pkgs.writeShellScriptBin "rebuild" ''
      exec sudo nixos-rebuild switch --refresh \
        --flake github:alx-alexpark/server-cfg#${config.networking.hostName} "$@"
    '')
  ];
}
