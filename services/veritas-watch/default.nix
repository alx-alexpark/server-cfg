{
  lib,
  pkgs,
  ...
}:
# Checks https://www.theveritassearch.com/ and pushes an ntfy alert when the
# LLM (Hack Club AI) judges a change significant. watch.py is stdlib-only.
# A full check (render every page + diff, LLM only if something changed) runs
# every 2 minutes. For a lighter mode, raise FULL_EVERY_MIN: runs in between
# then only fetch index.html and do a full check if it changed (= new deploy).
{
  # The repo is public, so secrets (and the ntfy topic, which anyone could
  # subscribe to) live on the server. Create before the first run, as root:
  #   install -d -m 700 /var/lib/secrets
  #   install -m 600 /dev/null /var/lib/secrets/veritas-watch.env
  #   then add HACKCLUB_AI_KEY=... and NTFY_TOPIC=...
  systemd.services.veritas-watch = {
    description = "Watch theveritassearch.com for changes";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      CHROME = lib.getExe pkgs.chromium;
      DATA_DIR = "/var/lib/veritas-watch";
      FULL_EVERY_MIN = "0"; # every run is a full check
    };
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = "/var/lib/secrets/veritas-watch.env";
      ExecStart = "${lib.getExe pkgs.python3} -I ${./watch.py}";
      DynamicUser = true;
      StateDirectory = "veritas-watch"; # snapshot.json + history/ of past diffs
      TimeoutStartSec = "20min";

      # Hardening. Not set on purpose: MemoryDenyWriteExecute (V8's JIT needs
      # W+X) and RestrictNamespaces/PrivateUsers (Chromium's sandbox uses user
      # namespaces).
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      CapabilityBoundingSet = "";
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      MemoryMax = "1500M";
    };
  };

  systemd.timers.veritas-watch = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/2"; # every 2 minutes
      # default accuracy is 1min, which would let runs drift
      AccuracySec = "1s";
      # if a check ever runs long, systemd won't start a second copy of a
      # running oneshot, so runs queue instead of overlapping
    };
  };
}
