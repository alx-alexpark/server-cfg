{
  config,
  lib,
  ...
}:
let
  domain = "chg.sus.cx";
  # Turns on Caddy for the domain, behind basic auth. When false the UI is only
  # reachable over an SSH tunnel:
  #   ssh -L 5000:127.0.0.1:5000 root@<server>  then open http://localhost:5000
  public = true;

  docker = "${config.virtualisation.docker.package}/bin/docker";
  compose = "${docker} compose -p changedetection -f ${./docker-compose.yml}";
in
{
  # Only the plain HTTP fetcher is set up. A headless Chrome container for
  # JS-rendered pages would need more RAM than imposter4 has to spare.
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
  };

  systemd.services.changedetection = {
    description = "changedetection.io (docker compose)";
    wantedBy = [ "multi-user.target" ];
    after = [ "docker.service" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    environment.CHANGEDETECTION_DOMAIN = domain;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # --pull so restarts (e.g. the nightly auto-upgrade reboot) pick up new releases
      ExecStart = "${compose} up -d --pull always --remove-orphans";
      ExecStop = "${compose} down";
    };
  };

  services.caddy.virtualHosts = lib.mkIf public {
    # same user as search.sus.cx; make a new hash with `caddy hash-password`.
    # The REST API (x-api-key header) is behind this too.
    ${domain}.extraConfig = ''
      basic_auth {
        sussy $2a$14$caQAFHDF46tWUkQ0A7vMx.tm5hBPRCUefXhO1NKEcJ9X/tmgYHbom
      }
      reverse_proxy 127.0.0.1:5000
    '';
  };
}
