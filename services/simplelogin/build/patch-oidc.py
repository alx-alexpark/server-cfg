"""SussyNet's changes to SimpleLogin's Authentik (OIDC) login, applied when the
image is built. Each change must match exactly once, so the build fails instead
of shipping a half-patched login if upstream changes this code."""

import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()


def replace(old: str, new: str) -> None:
    global src
    if src.count(old) != 1:
        sys.exit(f"patch-oidc: expected exactly one {old!r} in {path}")
    src = src.replace(old, new)


# DISABLE_REGISTRATION closes every way to make an account, Authentik login
# included. Keep it for password sign-up, but let Authentik login create
# accounts: Authentik's simplelogin group decides who may use SimpleLogin.
replace(
    "    if not user and config.DISABLE_REGISTRATION:\n",
    "    if False:  # sussynet: Authentik decides who may sign up\n",
)

# SimpleLogin admin follows the Authentik group named in SUSSYNET_ADMIN_GROUP,
# checked on every SSO login: joining the group grants it, leaving takes it away.
replace(
    '    if not SocialAuth.get_by(user_id=user.id, social="oidc"):\n',
    '    admin_group = os.environ.get("SUSSYNET_ADMIN_GROUP")\n'
    "    if admin_group:\n"
    '        is_admin = admin_group in (oidc_user_data.get("groups") or [])\n'
    "        if user.is_admin != is_admin:\n"
    '            LOG.w(f"sussynet: is_admin={is_admin} for user {user.id} from Authentik groups")\n'
    "            user.is_admin = is_admin\n"
    "            Session.commit()\n"
    "\n"
    '    if not SocialAuth.get_by(user_id=user.id, social="oidc"):\n',
)
replace("import requests\n", "import os\n\nimport requests\n")

with open(path, "w") as f:
    f.write(src)
