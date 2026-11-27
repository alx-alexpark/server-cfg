{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = "fs.parkalex.dev";
  # Turns on Caddy for the domain, so share links work from anywhere. When false
  # the UI is only reachable over an SSH tunnel:
  #   ssh -L 8000:127.0.0.1:8000 root@<server>  then open http://localhost:8000
  public = true;

  # nginx serves Nextcloud here, behind Caddy, which owns 80/443
  port = 8000;

  # Nextcloud runs natively: PHP-FPM as the unprivileged `nextcloud` user, with
  # nginx, PHP, Postgres and Redis all from nixpkgs, so security fixes arrive
  # with the nightly auto-upgrade. Major versions don't: when nixpkgs marks this
  # one EOL the build fails, and it has to be bumped here by one major version.
  uid = 2001;

  # Its data directory, which holds the files, is the Storage Box (mounted in
  # hosts/amogus6/default.nix); config, database and cache stay on this disk.
  dataDir = "${config.services.nextcloud.datadir}/data";

  # The repo is public, so the admin password is generated on the server once:
  #   sudo cat /var/lib/secrets/nextcloud-admin
  # Change it after the first login; this file is only read when the user is created.
  admin = "alex";
  adminPassFile = "/var/lib/secrets/nextcloud-admin";

  # Shipped apps that are on by default but not needed for files and share
  # links. Each is more code reachable from the internet, phones home, or (app_api,
  # webhook_listeners) makes the server run or call other things.
  disabledApps = [
    "app_api"
    "circles"
    "comments"
    "contactsinteraction"
    "dashboard"
    "federation"
    "files_reminders"
    "firstrunwizard"
    "nextcloud_announcements"
    "office"
    "photos"
    "recommendations"
    "related_resources"
    "sharebymail"
    "support"
    "survey_client"
    "systemtags"
    "text"
    "updatenotification"
    "user_status"
    "weather_status"
    "webhook_listeners"
  ];

  # On top of the sandboxing nixpkgs already gives PHP-FPM
  hardening = {
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    LockPersonality = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
  };

  # Never run with the Storage Box missing, or Nextcloud would write to the
  # empty mountpoint on this disk
  needsData = {
    unitConfig.RequiresMountsFor = [ dataDir ];
  };
in
{
  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud35;
    hostName = domain;
    https = true;

    # Postgres over its Unix socket with peer auth: no database password exists
    database.createLocally = true;
    config.dbtype = "pgsql";
    # Redis over a Unix socket, for file locking and caching
    configureRedis = true;

    # No app store: only the apps shipped with the package, patched with it
    appstoreEnable = false;
    # ImageMagick is a frequent source of CVEs; JPEG/PNG/GIF previews still work via GD
    enableImagemagick = false;

    # Clients and the web UI upload in chunks, so this only caps single requests
    maxUploadSize = "1G";
    # Reassembling a big chunked upload reads and writes over the Storage Box
    fastcgiTimeout = 600;

    settings = {
      trusted_proxies = [
        "127.0.0.1"
        "::1"
      ];
      overwriteprotocol = "https";
      "overwrite.cli.url" = "https://${domain}";
      default_phone_region = "US";
      # Heavy background jobs between 03:00 and 07:00 New York time (UTC hours)
      maintenance_window_start = 8;
      # Don't publish profiles to Nextcloud's lookup server
      lookup_server = "";
      "simpleSignUpLink.shown" = false;
    };
  };

  # A fixed uid, so the Storage Box mount can hand its files to this user
  users.users.nextcloud.uid = uid;
  users.groups.nextcloud.gid = uid;

  # Only on localhost; Caddy terminates TLS in front of it
  services.nginx.virtualHosts.${domain}.listen = [
    {
      addr = "127.0.0.1";
      inherit port;
    }
  ];

  systemd.services = {
    phpfpm-nextcloud = lib.recursiveUpdate needsData { serviceConfig = hardening; };
    nextcloud-cron = lib.recursiveUpdate needsData { serviceConfig = hardening; };
    nextcloud-setup = needsData;
    nextcloud-update-db = needsData;

    # Runs on every boot and deploy; each step is a no-op once done
    nextcloud-bootstrap = {
      description = "Create the Nextcloud admin, turn off unneeded apps, require 2FA";
      wantedBy = [ "multi-user.target" ];
      after = [ "nextcloud-setup.service" ];
      requires = [ "nextcloud-setup.service" ];
      path = [
        config.services.nextcloud.occ
        pkgs.openssl
      ];
      # the occ wrapper reads $USER to decide whether to switch to nextcloud
      environment.USER = "root";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if ! nextcloud-occ user:info ${admin} >/dev/null 2>&1; then
          if [ ! -s ${adminPassFile} ]; then
            install -d -m 700 "$(dirname ${adminPassFile})"
            (umask 077; openssl rand -base64 24 > ${adminPassFile})
          fi
          OC_PASS=$(cat ${adminPassFile}) nextcloud-occ user:add \
            --password-from-env --group admin ${admin}
        fi
        nextcloud-occ app:disable ${lib.escapeShellArgs disabledApps} || true
        # Everyone sets up TOTP at their next login; desktop and phone clients
        # use app passwords from the login flow instead
        nextcloud-occ twofactorauth:enforce --on
      '';
    };
  };

  services.caddy.virtualHosts = lib.mkIf public {
    ${domain}.extraConfig = ''
      reverse_proxy 127.0.0.1:${toString port}
    '';
  };
}
