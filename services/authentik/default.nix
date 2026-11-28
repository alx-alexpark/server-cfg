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
  # subordinate uids). No outposts (the embedded one is off too), so nothing
  # needs a socket either.
  user = "authentik";
  uid = 2003;
  home = "/var/lib/authentik";
  secretsDir = "${home}/secrets";

  podman = "${config.virtualisation.podman.package}/bin/podman";

  # Django's password hash format, which AUTHENTIK_BOOTSTRAP_PASSWORD_HASH takes;
  # the same thing `ak hash_password` prints. Reads the password on stdin.
  hashPassword = pkgs.writeText "authentik-hash-password.py" ''
    import base64, hashlib, secrets, string, sys

    password = sys.stdin.readline().rstrip("\n")
    salt = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(22))
    iterations = 1000000
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), iterations)
    print("pbkdf2_sha256$%d$%s$%s" % (iterations, salt, base64.b64encode(digest).decode()))
  '';

  # The repo is public, so these are generated on the server once. The first
  # login is akadmin with the bootstrap password:
  #   sudo cat /var/lib/authentik/secrets/bootstrap-password
  # It is only used when the database is created, so there is no open setup page.
  # Authentik only gets its hash, as its docs recommend; delete the file once
  # akadmin's password is changed.
  generateSecrets = pkgs.writeShellScript "authentik-secrets" ''
    set -eu
    umask 077
    openssl=${pkgs.openssl}/bin/openssl
    hash_password() { ${pkgs.python3}/bin/python3 -I ${hashPassword}; }
    install -d -m 700 -o ${user} -g ${user} ${secretsDir}
    if [ ! -f ${secretsDir}/authentik.env ]; then
      pw=$($openssl rand -hex 32)
      bootstrap=$($openssl rand -base64 24)
      printf 'POSTGRES_PASSWORD=%s\n' "$pw" > ${secretsDir}/db.env
      printf 'AUTHENTIK_POSTGRESQL__PASSWORD=%s\nAUTHENTIK_SECRET_KEY=%s\nAUTHENTIK_BOOTSTRAP_PASSWORD_HASH=%s\n' \
        "$pw" "$($openssl rand -hex 50)" "$(printf '%s\n' "$bootstrap" | hash_password)" \
        > ${secretsDir}/authentik.env
      printf '%s\n' "$bootstrap" > ${secretsDir}/bootstrap-password
    fi
    # Installs from before kept the plain password in the env file; swap it for
    # its hash. Authentik only reads either one when it creates akadmin.
    if grep -q '^AUTHENTIK_BOOTSTRAP_PASSWORD=' ${secretsDir}/authentik.env; then
      hash=$(sed -n 's/^AUTHENTIK_BOOTSTRAP_PASSWORD=//p' ${secretsDir}/authentik.env | hash_password)
      tmp=$(mktemp -p ${secretsDir})
      grep -v '^AUTHENTIK_BOOTSTRAP_PASSWORD=' ${secretsDir}/authentik.env > "$tmp"
      printf 'AUTHENTIK_BOOTSTRAP_PASSWORD_HASH=%s\n' "$hash" >> "$tmp"
      mv "$tmp" ${secretsDir}/authentik.env
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
    command: extraEnvironment:
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
        # connects is Caddy (or root on the host): no untrusted client can reach
        # it directly, which is what the docs ask of this list. pasta hands those
        # connections to the pod from the server's public address, which comes
        # from DHCP, so trust the forwarded headers from anywhere.
        AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS = "0.0.0.0/0,::/0";
        # Only serves proxy providers, and there are none; no outposts at all
        AUTHENTIK_OUTPOSTS__DISABLE_EMBEDDED_OUTPOST = "true";
        # The setup page that asks for it is skipped (see generateSecrets), and
        # an empty Base URL falls back to the embedded outpost. Only fills in the
        # system setting while it is empty; it never overwrites one.
        AUTHENTIK_WEB__BASE_URL = "https://${domain}";
      }
      // extraEnvironment;
      environmentFiles = [ "${secretsDir}/authentik.env" ];
      # :U hands the directory to the container's uid
      volumes = [ "${home}/data:/data:U" ];
      extraOptions = [
        "--pod=authentik"
        "--cap-drop=all"
        "--security-opt=no-new-privileges"
      ];
    };

  # SussyNet branding, plus required two-factor. Blueprints are applied by the worker when their file
  # changes; the version line makes this one apply again after each upgrade,
  # in case an upgrade's default flows put "authentik" back in the titles.
  title = "SussyNet Authentication Services";
  brandingUrl = "https://${domain}/sussynet-branding";
  brandingBlueprint = pkgs.writeText "sussynet-branding.yaml" ''
    # authentik ${version}
    version: 1
    metadata:
      name: SussyNet branding
    entries:
      - model: authentik_brands.brand
        identifiers:
          domain: authentik-default
        conditions:
          - !Find [authentik_brands.brand, [domain, authentik-default]]
        attrs:
          branding_title: ${title}
          branding_logo: ${brandingUrl}/logo.png
          branding_favicon: ${brandingUrl}/favicon.png
          attributes:
            settings:
              theme:
                # the logo is made for a light background
                base: light
      - model: authentik_flows.flow
        identifiers:
          slug: default-authentication-flow
        conditions:
          - !Find [authentik_flows.flow, [slug, default-authentication-flow]]
        attrs:
          name: ${title}
          title: Sign in
      - model: authentik_flows.flow
        identifiers:
          slug: default-source-authentication
        conditions:
          - !Find [authentik_flows.flow, [slug, default-source-authentication]]
        attrs:
          title: Sign in
      - model: authentik_flows.flow
        identifiers:
          slug: default-source-enrollment
        conditions:
          - !Find [authentik_flows.flow, [slug, default-source-enrollment]]
        attrs:
          title: Choose a username

      # Two-factor is optional by default. Make it required: anyone without a
      # passkey/security key or TOTP app sets one up before they get in.
      - model: authentik_stages_authenticator_validate.authenticatorvalidatestage
        identifiers:
          name: default-authentication-mfa-validation
        conditions:
          - !Find [authentik_stages_authenticator_validate.authenticatorvalidatestage, [name, default-authentication-mfa-validation]]
        attrs:
          not_configured_action: configure
          configuration_stages:
            - !Find [authentik_stages_authenticator_webauthn.authenticatorwebauthnstage, [name, default-authenticator-webauthn-setup]]
            - !Find [authentik_stages_authenticator_totp.authenticatortotpstage, [name, default-authenticator-totp-setup]]
  '';
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
    authentik-server = authentik "server" { };
    # The worker serves its own health and metrics endpoints on the same default
    # ports as the server. They share the pod's network, so it would take 9000
    # and answer every page with a 404; keep it on the pod's loopback instead.
    authentik-worker =
      let
        worker = authentik "worker" {
          AUTHENTIK_LISTEN__HTTP = "127.0.0.1:9100";
          AUTHENTIK_LISTEN__METRICS = "127.0.0.1:9301";
        };
      in
      worker
      // {
        # our blueprints, read-only; the worker applies them when they change
        volumes = worker.volumes ++ [
          "${brandingBlueprint}:/blueprints/sussynet/branding.yaml:ro"
          "${./blueprints/enrollment.yaml}:/blueprints/sussynet/enrollment.yaml:ro"
        ];
      };
  };

  services.update-checker.releases.Authentik = {
    repo = "goauthentik/authentik";
    current = "version/${version}";
  };

  # Headers from Authentik's hardening guide that it doesn't send itself. The
  # CSP is the one the guide lists; "?" only adds it where Authentik set none,
  # so its stricter one on uploaded files stays.
  services.caddy.virtualHosts.${domain}.extraConfig = ''
    header {
      ?Content-Security-Policy "default-src 'self'; img-src https: data:; object-src 'none'; frame-ancestors 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'"
      ?Strict-Transport-Security "max-age=31536000"
    }
    # the logo and favicon the brand points at
    handle_path /sussynet-branding/* {
      root * ${./branding}
      file_server
    }
    handle {
      reverse_proxy 127.0.0.1:9000
    }
  '';
}
