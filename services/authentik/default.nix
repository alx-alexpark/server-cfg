{
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = "auth.parkalex.dev";

  # Pinned; the update checker (services/update-checker) says on Slack when a new
  # release is out. Upgrade one minor version (2026.8 -> 2026.11) at a time.
  version = "2026.8.7";

  # Authentik runs in rootless Podman as this unprivileged user, not under the
  # Docker daemon: there is no container socket anywhere, and root in its
  # containers is just this user on the host (everything else maps to its
  # subordinate uids). No outposts, so nothing needs a socket either.
  user = "authentik";
  uid = 2003;
  home = "/var/lib/authentik";
  secretsDir = "${home}/secrets";

  podman = "${config.virtualisation.podman.package}/bin/podman";

  # The repo is public, so these are generated on the server once. The first
  # login is akadmin with the bootstrap password:
  #   sudo cat /var/lib/authentik/secrets/bootstrap-password
  # It is only used when the database is created, so there is no open setup page.
  generateSecrets = pkgs.writeShellScript "authentik-secrets" ''
    set -eu
    umask 077
    openssl=${pkgs.openssl}/bin/openssl
    install -d -m 700 -o ${user} -g ${user} ${secretsDir}
    if [ ! -f ${secretsDir}/authentik.env ]; then
      pw=$($openssl rand -hex 32)
      bootstrap=$($openssl rand -base64 24)
      printf 'POSTGRES_PASSWORD=%s\n' "$pw" > ${secretsDir}/db.env
      printf 'AUTHENTIK_POSTGRESQL__PASSWORD=%s\nAUTHENTIK_SECRET_KEY=%s\nAUTHENTIK_BOOTSTRAP_PASSWORD=%s\n' \
        "$pw" "$($openssl rand -hex 50)" "$bootstrap" > ${secretsDir}/authentik.env
      printf '%s\n' "$bootstrap" > ${secretsDir}/bootstrap-password
    fi
    chown ${user}:${user} ${secretsDir}/*
    chmod 400 ${secretsDir}/*
  '';

  common = {
    podman.user = user;
    # picks up Postgres patch releases on restart; Authentik itself is pinned
    pull = "newer";
  };

  authentik =
    command:
    common
    // {
      image = "ghcr.io/goauthentik/server:${version}";
      cmd = [ command ];
      dependsOn = [ "authentik-postgresql" ];
      environment = {
        AUTHENTIK_POSTGRESQL__HOST = "127.0.0.1";
        AUTHENTIK_POSTGRESQL__NAME = "authentik";
        AUTHENTIK_POSTGRESQL__USER = "authentik";
        AUTHENTIK_DISABLE_UPDATE_CHECK = "true";
        AUTHENTIK_DISABLE_STARTUP_ANALYTICS = "true";
        AUTHENTIK_ERROR_REPORTING__ENABLED = "false";
        # The pod's only published port is on the host's loopback, so whatever
        # connects is Caddy (or root on the host). Podman's port forwarding can
        # change the source address, so trust the forwarded headers from anywhere.
        AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS = "0.0.0.0/0,::/0";
      };
      environmentFiles = [ "${secretsDir}/authentik.env" ];
      # :U hands the directory to the container's uid
      volumes = [ "${home}/data:/data:U" ];
      extraOptions = [
        "--pod=authentik"
        "--cap-drop=all"
        "--security-opt=no-new-privileges"
      ];
    };
in
{
  imports = [ ../update-checker ];

  users.users.${user} = {
    isSystemUser = true;
    group = user;
    inherit uid home;
    createHome = true;
    # starts its user manager at boot, which rootless Podman needs
    linger = true;
    subUidRanges = [
      {
        startUid = 200000;
        count = 65536;
      }
    ];
    subGidRanges = [
      {
        startGid = 200000;
        count = 65536;
      }
    ];
  };
  users.groups.${user}.gid = uid;

  systemd.tmpfiles.rules = [
    "d ${home}/postgres 0700 ${user} ${user} -"
    "d ${home}/data 0700 ${user} ${user} -"
  ];

  virtualisation.oci-containers.backend = "podman";

  # Postgres, the server and the worker share one pod, so they talk over its
  # localhost and only the web port leaves it.
  systemd.services = {
    authentik-pod = {
      description = "Podman pod for Authentik";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "linger-users.service"
      ];
      after = [
        "network-online.target"
        "linger-users.service"
        "user@${toString uid}.service"
      ];
      environment.HOME = home;
      unitConfig.RequiresMountsFor = "/run/user/${toString uid}/containers";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        # "+" runs the secret generation as root, then hands the files over
        ExecStartPre = "+${generateSecrets}";
        ExecStart = lib.escapeShellArgs [
          podman
          "pod"
          "create"
          "--replace"
          "--name=authentik"
          "--infra-name=authentik-infra"
          # only ever reachable through Caddy
          "--publish=127.0.0.1:9000:9000"
          "--shm-size=512m"
        ];
        ExecStop = "${podman} pod rm --force --ignore authentik";
      };
    };
  }
  # Every container goes down and comes back with the pod
  //
    lib.genAttrs
      [
        "podman-authentik-postgresql"
        "podman-authentik-server"
        "podman-authentik-worker"
      ]
      (_: {
        requires = [ "authentik-pod.service" ];
        after = [ "authentik-pod.service" ];
      });

  virtualisation.oci-containers.containers = {
    authentik-postgresql = common // {
      image = "docker.io/library/postgres:16-alpine";
      environment = {
        POSTGRES_USER = "authentik";
        POSTGRES_DB = "authentik";
      };
      environmentFiles = [ "${secretsDir}/db.env" ];
      volumes = [ "${home}/postgres:/var/lib/postgresql/data" ];
      extraOptions = [
        "--pod=authentik"
        "--security-opt=no-new-privileges"
      ];
    };
    authentik-server = authentik "server";
    authentik-worker = authentik "worker";
  };

  services.update-checker.releases.Authentik = {
    repo = "goauthentik/authentik";
    current = "version/${version}";
  };

  services.caddy.virtualHosts.${domain}.extraConfig = ''
    reverse_proxy 127.0.0.1:9000
  '';
}
