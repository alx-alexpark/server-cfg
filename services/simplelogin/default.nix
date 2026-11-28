{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Aliases are x@m.sus.cx and the web UI is https://m.sus.cx. The sus.cx root
  # stays with Migadu. DNS, all with Cloudflare's proxy off:
  #   m.sus.cx                 A     178.105.241.24
  #   m.sus.cx                 AAAA  2a01:4f8:c17:4066::1
  #   m.sus.cx                 MX 10 m.sus.cx.
  #   m.sus.cx                 TXT   "v=spf1 mx -all"
  #   dkim._domainkey.m.sus.cx TXT   output of `simplelogin-dkim-record` on the server
  #   _dmarc.m.sus.cx          TXT   "v=DMARC1; p=quarantine; adkim=r; aspf=r"
  # Also set reverse DNS for both addresses to m.sus.cx in the Hetzner console,
  # and ask Hetzner support to unblock outgoing port 25, or nothing gets delivered.
  domain = "m.sus.cx";

  # Pinned, because every upgrade runs database migrations; the update checker
  # (services/update-checker) says on Slack when a new release is out.
  # simplelogin/app on Docker Hub stopped in 2022; app-ci has the releases.
  version = "v4.83.7";

  # Owns the keys and data directories; the app containers run as it
  uid = 2002;

  # The compose network the app containers send mail from
  subnet = "10.250.25.0/24";
  gateway = "10.250.25.1";

  docker = "${config.virtualisation.docker.package}/bin/docker";
  compose = "${docker} compose -p simplelogin -f ${./docker-compose.yml}";
  secretsFile = "/var/lib/secrets/simplelogin.env";
  keysDir = "/var/lib/simplelogin/keys";

  # The repo is public, so the DB password, Flask secret and keys are generated
  # on the server once.
  generateSecrets = pkgs.writeShellScript "simplelogin-secrets" ''
    set -eu
    umask 077
    openssl=${pkgs.openssl}/bin/openssl
    if [ ! -f ${secretsFile} ]; then
      install -d -m 700 "$(dirname ${secretsFile})"
      pw=$($openssl rand -hex 32)
      printf 'POSTGRES_PASSWORD=%s\nDB_URI=postgresql://simplelogin:%s@db:5432/simplelogin\nFLASK_SECRET=%s\n' \
        "$pw" "$pw" "$($openssl rand -hex 32)" > ${secretsFile}
    fi
    for key in dkim jwtRS256; do
      if [ ! -f ${keysDir}/$key.key ]; then
        $openssl genrsa -traditional -out ${keysDir}/$key.key 2048
      fi
      $openssl rsa -in ${keysDir}/$key.key -pubout -out ${keysDir}/$key.key.pub 2>/dev/null
    done
    chown root:simplelogin ${keysDir}/*
    chmod 640 ${keysDir}/*
  '';

  # As root on the server, after the first start:
  #   simplelogin-add-user you@example.com
  # The address is where your aliases forward to, and has to match your email in
  # Authentik for its login button to work. The account gets unlimited aliases.
  addUser = pkgs.writeShellScriptBin "simplelogin-add-user" ''
    set -eu
    if [ $# -ne 1 ]; then
      echo "usage: simplelogin-add-user EMAIL" >&2
      exit 1
    fi
    ${docker} exec -i simplelogin-app python - "$1" <<'EOF'
    import sys
    from server import create_light_app
    from app.db import Session
    from app.models import User

    email = sys.argv[1]
    with create_light_app().app_context():
        user = User.get_by(email=email)
        if user is None:
            user = User.create(email=email, name=email.split("@")[0], password="", activated=True)
        user.lifetime = True
        Session.commit()
        print(f"{email} is ready, with unlimited aliases")
    EOF
  '';

  # Prints the TXT value for dkim._domainkey.${domain}
  dkimRecord = pkgs.writeShellScriptBin "simplelogin-dkim-record" ''
    set -eu
    key=$(grep -v -- ----- ${keysDir}/dkim.key.pub | tr -d '\n')
    echo "v=DKIM1; k=rsa; p=$key"
  '';
in
{
  imports = [ ../update-checker ];

  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  users.users.simplelogin = {
    isSystemUser = true;
    group = "simplelogin";
    inherit uid;
  };
  users.groups.simplelogin.gid = uid;

  systemd.tmpfiles.rules = [
    "d /var/lib/simplelogin 0755 root root -"
    "d /var/lib/simplelogin/postgres 0700 root root -"
    "d ${keysDir} 0750 root simplelogin -"
    "d /var/lib/simplelogin/pgp 0700 simplelogin simplelogin -"
    "d /var/lib/simplelogin/upload 0700 simplelogin simplelogin -"
  ];

  systemd.services.simplelogin = {
    description = "SimpleLogin (docker compose)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "docker.service"
      "network-online.target"
      # OIDC_CLIENT_ID/SECRET, shared with Authentik (services/authentik)
      "simplelogin-oidc-secret.service"
    ];
    requires = [ "docker.service" ];
    wants = [
      "network-online.target"
      "simplelogin-oidc-secret.service"
    ];
    environment = {
      SL_DOMAIN = domain;
      SL_VERSION = version;
      SL_UID = toString uid;
      SL_SUBNET = subnet;
      SL_POSTFIX = gateway;
      # the Authentik application with slug "simplelogin" (services/authentik)
      SL_OIDC_WELL_KNOWN_URL = "https://auth.parkalex.dev/application/o/simplelogin/.well-known/openid-configuration";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = generateSecrets;
      # --build applies the patch in docker-compose.yml (cached after the first
      # time); Postgres is pulled on every start, SimpleLogin itself is pinned
      ExecStart = "${compose} up -d --build --remove-orphans";
      ExecStop = "${compose} down";
    };
  };

  environment.systemPackages = [
    addUser
    dkimRecord
  ];

  services.update-checker.releases.SimpleLogin = {
    repo = "simple-login/app";
    current = version;
  };

  # Postfix on the host, from nixpkgs: it takes mail for ${domain} from the
  # internet and hands it to SimpleLogin's email handler, and sends what
  # SimpleLogin gives it. DKIM signing is done by SimpleLogin itself.
  services.postfix = {
    enable = true;
    transport = ''
      ${domain} smtp:[127.0.0.1]:20381
    '';
    settings.main = {
      myhostname = domain;
      myorigin = domain;
      # nothing is delivered to local mailboxes
      mydestination = [ ];
      relay_domains = [ domain ];
      # only these may send mail out through it: the host and SimpleLogin
      mynetworks = [
        "127.0.0.0/8"
        "[::1]/128"
        subnet
      ];
      message_size_limit = 26214400; # 25 MiB
      disable_vrfy_command = true;

      # Opportunistic TLS both ways. Other servers don't check the certificate,
      # so a self-signed one is enough.
      smtpd_tls_chain_files = [
        "/var/lib/postfix-tls/key.pem"
        "/var/lib/postfix-tls/cert.pem"
      ];
      smtpd_tls_security_level = "may";
      smtp_tls_security_level = "may";

      smtpd_helo_required = true;
      smtpd_helo_restrictions = [
        "permit_mynetworks"
        "reject_non_fqdn_helo_hostname"
        "reject_invalid_helo_hostname"
        "permit"
      ];
      smtpd_sender_restrictions = [
        "permit_mynetworks"
        "reject_non_fqdn_sender"
        "reject_unknown_sender_domain"
        "permit"
      ];
      # The Spamhaus ranges skip its "you're querying through a public resolver" answers
      smtpd_recipient_restrictions = [
        "reject_unauth_pipelining"
        "reject_non_fqdn_recipient"
        "reject_unknown_recipient_domain"
        "permit_mynetworks"
        "reject_unauth_destination"
        "reject_rbl_client zen.spamhaus.org=127.0.0.[2..11]"
        "reject_rhsbl_sender dbl.spamhaus.org=127.0.1.[2..99]"
        "reject_rhsbl_helo dbl.spamhaus.org=127.0.1.[2..99]"
        "reject_rhsbl_reverse_client dbl.spamhaus.org=127.0.1.[2..99]"
        "permit"
      ];
    };
  };

  systemd.services.postfix-tls = {
    description = "Generate Postfix's self-signed certificate";
    wantedBy = [ "multi-user.target" ];
    before = [ "postfix.service" ];
    requiredBy = [ "postfix.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "postfix-tls";
      StateDirectoryMode = "0700";
    };
    script = ''
      if [ ! -f /var/lib/postfix-tls/cert.pem ]; then
        umask 077
        ${pkgs.openssl}/bin/openssl req -x509 -nodes -newkey rsa:2048 -days 36500 \
          -subj /CN=${domain} \
          -keyout /var/lib/postfix-tls/key.pem -out /var/lib/postfix-tls/cert.pem
      fi
    '';
  };

  networking.firewall.allowedTCPPorts = [ 25 ];

  services.caddy.virtualHosts.${domain}.extraConfig = ''
    reverse_proxy 127.0.0.1:7777
  '';
}
