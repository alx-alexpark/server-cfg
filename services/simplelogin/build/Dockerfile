# Upstream's pinned image with SussyNet's changes to its Authentik login
# (patch-oidc.py). Built on the server by docker compose (docker-compose.yml).
ARG SL_VERSION
FROM docker.io/simplelogin/app-ci:${SL_VERSION}
COPY patch-oidc.py /tmp/patch-oidc.py
RUN python /tmp/patch-oidc.py app/auth/views/oidc.py \
    && python -m compileall -q app/auth/views/oidc.py \
    && rm /tmp/patch-oidc.py
