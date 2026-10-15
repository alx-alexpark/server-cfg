{ config, ... }:
{
  system.autoUpgrade = {
    enable = true;
    flake = "github:alx-alexpark/server-cfg#${config.networking.hostName}";
    # flake.lock is bumped daily by .github/workflows/update-flake.yml
    flags = [ "--refresh" ];
    # run inside the reboot window, otherwise reboots would always be skipped
    dates = "03:00";
    randomizedDelaySec = "30min";
    allowReboot = true;
    rebootWindow = {
      lower = "03:00";
      upper = "06:00";
    };
  };
}
