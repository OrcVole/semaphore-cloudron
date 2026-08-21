#!/bin/bash
set -eu

mkdir -p /app/data/keys /app/data/home /run/semaphore/tmp /run/semaphore/ansible-tmp /run/semaphore/ansible-remote-tmp

# Take ownership of the WHOLE data volume, not only the directories created above. A Cloudron
# restore returns /app/data owned by a foreign uid, and anything this script does not explicitly
# chown keeps it. Git then refuses a repository whose owner differs from the caller ("dubious
# ownership") and every task fails at `Cloning Repository ... exit status 128`, so every project
# repository an install has accumulated becomes unusable after a restore. Row counts and content
# checksums survive that untouched, so it is invisible to anything but running a real task.
chown -R cloudron:cloudron /app/data
chown -R cloudron:cloudron /run/semaphore

# A writable HOME. The cloudron user's home is /home/cloudron and it is read-only, so
# `ansible-playbook` aborts before doing any work:
#   ERROR: Unable to create local directories(/home/cloudron/.ansible/tmp): Read-only file system
# The application is healthy and can be signed into in that state, and cannot run a playbook.
#
# HOME lives on /app/data because it also holds SSH known_hosts and any user ansible.cfg, and those
# should survive a restart. The temporary trees go on /run, which is cleared on restart and not
# backed up: scratch space in a backup is waste.
export HOME=/app/data/home
export ANSIBLE_HOME=/app/data/home/.ansible
export ANSIBLE_LOCAL_TEMP=/run/semaphore/ansible-tmp
# The target-side temp as well, and it is a separate setting. ANSIBLE_LOCAL_TEMP is the controller's;
# every module Ansible ships to a target unpacks under `remote_tmp`, which defaults to ~/.ansible/tmp
# and is expanded from the passwd entry rather than from the HOME exported above. On a
# `connection: local` play the target is this same read-only-home container, so without this every
# module transfer fails with UNREACHABLE!. A playbook that only uses `debug` will not show it; one
# that gathers facts or runs any real module will.
export ANSIBLE_REMOTE_TEMP=/run/semaphore/ansible-remote-tmp

# Outbound SSH to managed hosts writes known_hosts under $HOME/.ssh, and OpenSSH refuses a
# world-readable directory, so create it with the right mode rather than letting the first
# connection fail on a permissions check.
mkdir -p /app/data/home/.ssh
chown cloudron:cloudron /app/data/home/.ssh
chmod 700 /app/data/home/.ssh

export SEMAPHORE_DB_DIALECT=postgres
# The port belongs inside the host value. There is no separate port variable: the connection string
# is built as postgres://user:pass@<host>/<dbname>, so <host> carries host:port.
export SEMAPHORE_DB_HOST="$CLOUDRON_POSTGRESQL_HOST:$CLOUDRON_POSTGRESQL_PORT"
export SEMAPHORE_DB_USER="$CLOUDRON_POSTGRESQL_USERNAME"
export SEMAPHORE_DB_PASS="$CLOUDRON_POSTGRESQL_PASSWORD"
export SEMAPHORE_DB="$CLOUDRON_POSTGRESQL_DATABASE"
# lib/pq defaults to sslmode=require and the Cloudron postgresql addon serves no TLS, so without
# this the application panics at startup with `pq: SSL is not enabled on the server`. Options
# becomes the DSN query string, which is the correct home for it.
export SEMAPHORE_DB_OPTIONS='{"sslmode":"disable"}'
export SEMAPHORE_PORT=":3000"
export SEMAPHORE_TMP_PATH=/run/semaphore/tmp
export SEMAPHORE_WEB_ROOT="$CLOUDRON_APP_ORIGIN"
export SEMAPHORE_ENCRYPTION_KEYS_FILE=/app/data/keys/keyring.yml

# This package generates its own encryption keyring on first run and never overwrites an existing
# one. Upstream's defaults are both unacceptable: with no key configured the encryption function
# returns the plaintext base64-encoded, so users' private SSH keys sit in the database effectively in
# the clear with no warning; and the shipped compose file carries a literal, publicly known key.
#
# The keys map takes a KeySource object per key, not a bare string.
if [ ! -f /app/data/keys/keyring.yml ]; then
    KEY_ID="key1"
    KEY=$(head -c 32 /dev/urandom | base64)
    cat > /app/data/keys/keyring.yml <<EOF
keys:
  ${KEY_ID}:
    value: "${KEY}"
active:
  secret_key: "${KEY_ID}"
EOF
    # Chown and chmod the FILE, not just its directory: this holds the key that protects every
    # stored SSH key, password and token, and the default umask would leave it world-readable.
    chown cloudron:cloudron /app/data/keys/keyring.yml
    chmod 600 /app/data/keys/keyring.yml
fi

# Session cookie secrets. Without them the health endpoint answers, an administrator can be created,
# and every sign-in still fails with `Failed to create session` and `securecookie: hash key is not
# set` in the log.
#
# They must persist: regenerating them on restart silently invalidates every existing session, so
# they live on /app/data beside the keyring rather than on /run.
COOKIES=/app/data/keys/cookies.env
if [ ! -f "$COOKIES" ]; then
    {
      echo "SEMAPHORE_COOKIE_HASH=$(head -c 32 /dev/urandom | base64 -w0)"
      echo "SEMAPHORE_COOKIE_ENCRYPTION=$(head -c 32 /dev/urandom | base64 -w0)"
    } > "$COOKIES"
    chown cloudron:cloudron "$COOKIES"
    chmod 600 "$COOKIES"
fi
# shellcheck disable=SC1090
set -a; . "$COOKIES"; set +a

# Cloudron single sign-on. The provider is keyed `cloudron`, so the callback the application
# registers is /api/auth/oidc/cloudron/redirect and the manifest's loginRedirectUri must match it
# exactly. provider_url drives OpenID auto-discovery from the platform's issuer.
#
# Worth knowing: `password_login_disable` in this application is advertisement only -- the login
# handler never consults it -- so local password login stays reachable over the API even when the
# interface hides the form. This package is not SSO-only, and should not be described as such.
# Users created through single sign-on are external and are never administrators, which is why the
# first administrator still has to be created locally.
OIDC_BLOCK='{}'
if [ -n "${CLOUDRON_OIDC_ISSUER:-}" ]; then
    OIDC_BLOCK=$(python3 - <<'PYOIDC'
import json, os
print(json.dumps({"cloudron": {
    "display_name":   "Cloudron",
    "provider_url":   os.environ["CLOUDRON_OIDC_ISSUER"],
    "client_id":      os.environ["CLOUDRON_OIDC_CLIENT_ID"],
    "client_secret":  os.environ["CLOUDRON_OIDC_CLIENT_SECRET"],
    "redirect_url":   os.environ["CLOUDRON_APP_ORIGIN"].rstrip("/") + "/api/auth/oidc/cloudron/redirect",
    "scopes":         ["openid", "profile", "email"],
    "username_claim": "preferred_username",
    "email_claim":    "email",
    "name_claim":     "name",
    "order":          1,
}}))
PYOIDC
)
fi

# The database settings go in the config FILE as well as the environment. Exports live in this
# script's process only, so `semaphore ... --config /run/semaphore/config.json` run by an operator in
# the app's Terminal would otherwise inherit none of them and fall back to the default host,
# failing with `dial tcp 0.0.0.0:5432: connect: connection refused`. Note also that `port` is a
# string with a leading colon; an integer here fails to parse and config load is fatal.
#
# max_parallel_tasks is capped deliberately. Upstream defaults it to 9999, and since every task
# forks its own Ansible process that makes the container's memory limit unenforceable in principle.
cat > /run/semaphore/config.json <<EOF
{
  "port": ":3000",
  "dialect": "postgres",
  "postgres": {
    "host": "${CLOUDRON_POSTGRESQL_HOST}:${CLOUDRON_POSTGRESQL_PORT}",
    "user": "${CLOUDRON_POSTGRESQL_USERNAME}",
    "pass": "${CLOUDRON_POSTGRESQL_PASSWORD}",
    "name": "${CLOUDRON_POSTGRESQL_DATABASE}",
    "options": { "sslmode": "disable" }
  },
  "encryption": {
    "keys_file": "/app/data/keys/keyring.yml"
  },
  "web_host": "${CLOUDRON_APP_ORIGIN}",
  "oidc_providers": ${OIDC_BLOCK},
  "tmp_path": "/run/semaphore/tmp",
  "forwarded_env_vars": ["ANSIBLE_LOCAL_TEMP", "ANSIBLE_REMOTE_TEMP", "ANSIBLE_HOME"],
  "max_parallel_tasks": 10
}
EOF
chown cloudron:cloudron /run/semaphore/config.json
chmod 600 /run/semaphore/config.json

# First-run administrator. Without this the application has no usable account at all: a user who
# signs in with Cloudron single sign-on arrives EXTERNAL and is never an administrator, and
# `non_admin_can_create_project` defaults to false upstream -- so the first person to sign in cannot
# create a project, cannot administer anything, and has no way forward from the interface. Creating
# one here also runs the database migrations before the server starts.
#
# The credential is written once to a file the operator can read from the app's Terminal, and the
# file is the marker: if it exists, this has already run.
ADMIN_FILE=/app/data/.initial-admin
if [ ! -f "$ADMIN_FILE" ]; then
    ADMIN_PW="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"
    if gosu cloudron /app/code/bin/semaphore user add --admin \
         --login admin --name "Administrator" --email admin@localhost \
         --password "$ADMIN_PW" --config /run/semaphore/config.json >/dev/null 2>&1; then
        { echo "username: admin"
          echo "password: ${ADMIN_PW}"
          echo
          echo "Created automatically on first run. Sign in, change this password, then promote"
          echo "your own single sign-on account to administrator from Team -> Users."
        } > "$ADMIN_FILE"
        chown cloudron:cloudron "$ADMIN_FILE"
        chmod 600 "$ADMIN_FILE"
    fi
fi

exec gosu cloudron:cloudron /app/code/bin/semaphore server --config /run/semaphore/config.json
