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

  # Seafile runs as rootless Podman containers under this user. Container root is
  # this unprivileged user on the host, so breaking out of a container gets you
  # only Seafile's own files: no root, no Docker socket, no other services' data.
  user = "seafile";
  uid = 2000;
  home = "/var/lib/seafile";

  # File blocks, commits and fs objects (the bulk) live on the Storage Box,
  # mounted by root in hosts/amogus6/default.nix. Its SSH key stays root-only, so
  # this user can use the mounted files but never the Storage Box account.
  storageBox = "/mnt/storagebox";
  storage = "${storageBox}/storage";

  secretsFile = "${home}/secrets.env";
  network = "seafile";
  runtimeEnv = {
    HOME = home;
    XDG_RUNTIME_DIR = "/run/user/${toString uid}";
  };

  # Runs as the seafile user. The repo is public, so passwords and keys are
  # generated on the server once. The admin login is only used on first start:
  #   sudo grep INIT_SEAFILE_ADMIN /var/lib/seafile/secrets.env
  prepare = pkgs.writeShellScript "seafile-prepare" ''
    set -eu
    umask 077
    mkdir -p ${home}/shared ${home}/mysql ${storage}
    if [ ! -f ${secretsFile} ]; then
      rand() { ${pkgs.openssl}/bin/openssl rand -hex "$1"; }
      root=$(rand 32)
      cat > ${secretsFile}.tmp <<EOF
    MYSQL_ROOT_PASSWORD=$root
    INIT_SEAFILE_MYSQL_ROOT_PASSWORD=$root
    SEAFILE_MYSQL_DB_PASSWORD=$(rand 32)
    REDIS_PASSWORD=$(rand 32)
    JWT_PRIVATE_KEY=$(rand 32)
    INIT_SEAFILE_ADMIN_EMAIL=admin@${domain}
    INIT_SEAFILE_ADMIN_PASSWORD=$(rand 16)
    EOF
      mv ${secretsFile}.tmp ${secretsFile}
    fi
    podman network exists ${network} || podman network create ${network}
  '';

  # Shared by all three containers
  common = {
    podman.user = user;
    networks = [ network ];
    environmentFiles = [ secretsFile ];
    # --pull newer so restarts (e.g. the nightly auto-upgrade reboot) pick up patch releases
    pull = "newer";
    extraOptions = [
      "--security-opt=no-new-privileges"
      "--cap-drop=NET_RAW"
    ];
  };
in
{
  users.users.${user} = {
    inherit uid home;
    isSystemUser = true;
    group = user;
    createHome = true;
    homeMode = "700";
    # rootless Podman maps container users onto these
    autoSubUidGidRange = true;
    # keeps the user's systemd and Podman runtime up without anyone logged in
    linger = true;
  };
  users.groups.${user}.gid = uid;

  systemd.services = lib.mkMerge [
    {
      seafile-prepare = {
        description = "Seafile secrets, directories and Podman network";
        after = [ "user@${toString uid}.service" ];
        requires = [ "user@${toString uid}.service" ];
        path = [ config.virtualisation.podman.package ];
        environment = runtimeEnv;
        # Never run with the Storage Box missing, or Seafile would write blocks to
        # the server's own disk under the empty mountpoint.
        unitConfig.RequiresMountsFor = [ storageBox ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = user;
          ExecStart = prepare;
        };
      };
    }

    # Unit names are podman-<name>.service
    (lib.genAttrs [ "podman-seafile" "podman-seafile-db" "podman-seafile-redis" ] (_: {
      after = [ "seafile-prepare.service" ];
      requires = [ "seafile-prepare.service" ];
    }))

    { podman-seafile.unitConfig.RequiresMountsFor = [ storageBox ]; }
  ];

  virtualisation.oci-containers.backend = "podman";
  virtualisation.oci-containers.containers = {
    seafile-db = lib.recursiveUpdate common {
      image = "docker.io/library/mariadb:10.11";
      environment = {
        MYSQL_LOG_CONSOLE = "true";
        MARIADB_AUTO_UPGRADE = "1";
      };
      volumes = [ "${home}/mysql:/var/lib/mysql" ];
      # Seafile waits until the database answers
      podman.sdnotify = "healthy";
      extraOptions = common.extraOptions ++ [
        "--health-cmd=healthcheck.sh --connect --innodb_initialized"
        "--health-interval=20s"
        "--health-start-period=30s"
        "--health-timeout=5s"
        "--health-retries=10"
      ];
    };

    seafile-redis = lib.recursiveUpdate common {
      image = "docker.io/library/redis:8-alpine";
      user = "redis";
      # cache only, nothing written to disk
      cmd = [
        "sh"
        "-c"
        ''exec redis-server --requirepass "$REDIS_PASSWORD" --save "" --appendonly no''
      ];
    };

    seafile = lib.recursiveUpdate common {
      image = "docker.io/seafileltd/seafile-mc:13.0-latest";
      dependsOn = [
        "seafile-db"
        "seafile-redis"
      ];
      environment = {
        SEAFILE_SERVER_HOSTNAME = domain;
        SEAFILE_SERVER_PROTOCOL = "https";
        SEAFILE_MYSQL_DB_HOST = "seafile-db";
        SEAFILE_MYSQL_DB_USER = "seafile";
        TIME_ZONE = config.time.timeZone;
        CACHE_PROVIDER = "redis";
        REDIS_HOST = "seafile-redis";
        REDIS_PORT = "6379";
        ENABLE_GO_FILESERVER = "true";
        # extras that each add another server to attack; files only
        ENABLE_SEADOC = "false";
        ENABLE_NOTIFICATION_SERVER = "false";
        ENABLE_SEAFILE_AI = "false";
      };
      volumes = [
        # config, logs, thumbnails, avatars: small, stays on the server's disk
        "${home}/shared:/shared"
        "${storage}:/shared/seafile/seafile-data/storage"
      ];
      # only ever reachable through Caddy or an SSH tunnel
      ports = [ "127.0.0.1:8000:80" ];
    };
  };

  services.caddy.virtualHosts = lib.mkIf public {
    ${domain}.extraConfig = ''
      reverse_proxy 127.0.0.1:8000
    '';
  };
}
