{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.update-checker;

  # The repo is public, so the webhook lives only on the server. As root:
  #   install -m 600 /dev/stdin /var/lib/secrets/slack-webhook
  # then paste the URL, press Enter, then Ctrl-D.
  webhookFile = "/var/lib/secrets/slack-webhook";

  releasesFile = pkgs.writeText "releases.tsv" (
    lib.concatStrings (lib.mapAttrsToList (name: r: "${name}\t${r.repo}\t${r.current}\n") cfg.releases)
  );

  checker = pkgs.writeShellApplication {
    name = "update-checker";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.findutils
      pkgs.jq
    ];
    text = builtins.readFile ./check.sh;
  };
in
{
  # Services with pinned versions add themselves here
  options.services.update-checker.releases = lib.mkOption {
    default = { };
    description = "GitHub repos whose latest release is compared against the deployed tag.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          repo = lib.mkOption {
            type = lib.types.str;
            description = "owner/name on GitHub";
          };
          current = lib.mkOption {
            type = lib.types.str;
            description = "The deployed release's tag, exactly as GitHub names it";
          };
        };
      }
    );
  };

  config = lib.mkIf (cfg.releases != { }) {
    systemd.services.update-checker = {
      description = "Tell Slack about new releases of pinned services";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe checker} ${releasesFile} ${config.networking.hostName}";
        # the webhook is handed over by systemd and readable only by this run
        LoadCredential = "slack-webhook:${webhookFile}";
        DynamicUser = true;
        StateDirectory = "update-checker";
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        UMask = "0077";
      };
    };

    systemd.timers.update-checker = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 10:00";
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };
  };
}
