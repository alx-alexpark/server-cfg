{
  config,
  pkgs,
  receipt-printer,
  ...
}:
let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  compose = "${docker} compose -p receipt-printer -f ${./docker-compose.yml}";
  stateDir = "/var/lib/receipt-printer";
in
{
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  # The container runs as this user, not root; it owns only the state dir
  users.users.receipt = {
    isSystemUser = true;
    uid = 1500;
    group = "receipt";
  };
  users.groups.receipt.gid = 1500;

  systemd.tmpfiles.rules = [ "d ${stateDir} 0700 receipt receipt -" ];

  # Epson TM-T88V: let the lp group talk to it over USB
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="0202", GROUP="lp", MODE="0660"
  '';

  # Put config.toml (and token.json, for Google Calendar) in place before this runs, as root:
  #   install -m 600 -o receipt -g receipt config.toml token.json /var/lib/receipt-printer/
  systemd.services.receipt-briefing = {
    description = "Print the daily briefing (docker compose)";
    after = [ "docker.service" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    environment = {
      # receipt-printer is a flake input, bumped daily with the rest of flake.lock
      RECEIPT_SRC = "${receipt-printer}";
      RECEIPT_UID = toString config.users.users.receipt.uid;
      RECEIPT_GID = toString config.users.groups.receipt.gid;
      LP_GID = toString config.users.groups.lp.gid;
    };
    serviceConfig = {
      Type = "oneshot";
      # --build is a no-op when the source hasn't changed
      ExecStart = "${compose} run --rm --build briefing";
    };
  };

  systemd.timers.receipt-briefing = {
    wantedBy = [ "timers.target" ];
    # Server time (America/New_York). No Persistent: if the server was down at
    # print time, skip the day rather than print a stale briefing.
    timerConfig.OnCalendar = [
      "Mon,Wed,Fri 09:00"
      "Tue,Thu 10:30"
      "Sat,Sun 11:30"
    ];
  };

  # Open the CD tray when the printer drops off USB, so it's obvious it isn't working
  systemd.services.receipt-printercheck = {
    description = "Eject CD tray if the receipt printer is missing";
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      SupplementaryGroups = [ "cdrom" ];
      ExecStart = pkgs.writeShellScript "printercheck" ''
        ${pkgs.gnugrep}/bin/grep -qx 04b8 /sys/bus/usb/devices/*/idVendor 2>/dev/null && exit 0
        echo "printer not found on USB, ejecting CD tray" >&2
        exec ${pkgs.util-linux}/bin/eject
      '';
    };
  };

  systemd.timers.receipt-printercheck = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };
}
