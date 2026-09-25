#!/bin/bash
#
# Runtime smoke gate for the Semaphore UI Cloudron package. No box required: it runs the image the
# way Cloudron does (root entrypoint -> start.sh -> gosu cloudron, read-only root, /app/data as the
# only writable volume, tmpfs on /run and /tmp) against a throwaway PostgreSQL standing in for the
# postgresql addon, and asserts the package contract a build-time check cannot reach.
#
# What this defends:
#   * the app boots against the addon's environment (sslmode=disable, host:port in one value) and
#     answers the manifest's healthCheckPath, /api/ping;
#   * the web interface is served, including the login route, not only the API;
#   * the first-run administrator exists, its credential file is 0600, and the credential WORKS;
#   * the encryption keyring and cookie secrets are 0600 and are NEVER regenerated on restart
#     (a new keyring makes every stored secret undecryptable; new cookie secrets end every session);
#   * the server runs as cloudron, not root.
#
# Usage:  test/smoke.sh [IMAGE]    (default: ghcr.io/orcvole/semaphore-cloudron:<manifest version>)
#         PG_IMAGE=docker.io/library/postgres:14 overrides the stand-in database image.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

VERSION=$(grep -o '"version"[^,]*' CloudronManifest.json | head -1 | cut -d'"' -f4)
IMAGE="${1:-ghcr.io/orcvole/semaphore-cloudron:${VERSION}}"
PG_IMAGE="${PG_IMAGE:-docker.io/library/postgres:14}"
CRI="$(command -v podman || command -v docker)"

# --- identity guard (#188): refuse to test an image that is not this checkout's version ---------
# A tag nothing rebuilds will eventually hold a stale build, and every assertion below then passes
# against the wrong subject. ABORT, not FAIL: once the subject is wrong, later results mean nothing.
want=$(grep -o '"upstreamVersion"[^,]*' CloudronManifest.json | head -1 | cut -d'"' -f4)
got=$("$CRI" run --rm --entrypoint /app/code/bin/semaphore "$IMAGE" version 2>/dev/null \
      | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -z "$got" ] || [ "$want" != "$got" ]; then
  echo "ABORT: ${IMAGE} bakes semaphore '${got:-unreadable}', manifest says '${want}'." >&2
  echo "       Build from this checkout before smoking it (stale-tag trap, field guide #188)." >&2
  exit 2
fi
echo "identity: image bakes semaphore ${got}, matching the manifest"

TAG="semaphore-smoke-$$"
NET="$TAG-net"
PG="$TAG-pg"
APP="$TAG-app"
VOL="$TAG-data"
PORT="${PORT:-$(( 31000 + RANDOM % 1000 ))}"
B="http://127.0.0.1:${PORT}"
PGPASS="smoke-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

fails=0
ok()  { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails+1)); }

cleanup() {
  "$CRI" rm -f "$APP" "$PG" >/dev/null 2>&1
  "$CRI" volume rm "$VOL" >/dev/null 2>&1
  "$CRI" network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

echo "=== smoke: image=${IMAGE} database=${PG_IMAGE} ==="
"$CRI" network create "$NET" >/dev/null
"$CRI" volume create "$VOL" >/dev/null
"$CRI" run -d --name "$PG" --network "$NET" \
  -e POSTGRES_USER=smoke -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_DB=smoke \
  "$PG_IMAGE" >/dev/null || { echo "could not start postgres"; exit 1; }
for i in $(seq 1 30); do
  "$CRI" exec "$PG" pg_isready -U smoke -d smoke >/dev/null 2>&1 && break
  sleep 1
done

start_app() {
  # Deliberately NO --userns=keep-id and NO --user: Cloudron starts the container as root and
  # start.sh drops to cloudron itself; it needs root for the chown of /app/data.
  "$CRI" run -d --name "$APP" --network "$NET" \
    --read-only --tmpfs /run --tmpfs /tmp \
    -v "$VOL":/app/data \
    -p "127.0.0.1:${PORT}:3000" \
    -e CLOUDRON=1 \
    -e CLOUDRON_APP_ORIGIN="$B" \
    -e CLOUDRON_APP_DOMAIN="127.0.0.1" \
    -e CLOUDRON_POSTGRESQL_HOST="$PG" \
    -e CLOUDRON_POSTGRESQL_PORT=5432 \
    -e CLOUDRON_POSTGRESQL_USERNAME=smoke \
    -e CLOUDRON_POSTGRESQL_PASSWORD="$PGPASS" \
    -e CLOUDRON_POSTGRESQL_DATABASE=smoke \
    -e CLOUDRON_POSTGRESQL_URL="postgres://smoke:${PGPASS}@${PG}:5432/smoke" \
    "$IMAGE" >/dev/null
}

wait_health() {  # wait_health <seconds>
  local n="$1" code
  for i in $(seq 1 "$n"); do
    code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$B/api/ping" 2>/dev/null || echo 000)
    [ "$code" = "200" ] && return 0
    sleep 1
  done
  return 1
}

in_app() { "$CRI" exec "$APP" sh -c "$1" 2>/dev/null; }

start_app || { echo "could not start the app container"; exit 1; }

# 1. Health, on the manifest's healthCheckPath.
if wait_health 90; then
  body=$(curl -s -m 5 "$B/api/ping")
  [ "$body" = "pong" ] && ok "GET /api/ping answers 200 'pong'" || bad "GET /api/ping answered 200 but body='${body}'"
else
  bad "never became healthy on /api/ping"; "$CRI" logs "$APP" 2>&1 | tail -40; exit 1
fi

# 2. The web interface, and its login route, are served (the SPA answers the client route itself).
for path in / /auth/login; do
  page=$(curl -s -m 5 -w '\n%{http_code}' "$B$path")
  code=${page##*$'\n'}
  if [ "$code" = "200" ] && printf '%s' "$page" | grep -qi '<div id="app"\|<title>Semaphore'; then
    ok "GET ${path} serves the Semaphore web interface"
  else
    bad "GET ${path} returned HTTP ${code} without the web interface"
  fi
done

# 3. Unauthenticated API access is fenced.
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$B/api/projects")
[ "$code" = "401" ] || [ "$code" = "403" ] && ok "GET /api/projects without a session is refused (HTTP $code)" \
  || bad "GET /api/projects without a session returned HTTP $code"

# 4. The first-run administrator: file present, 0600, and the credential actually signs in.
perms=$(in_app 'stat -c "%a %U" /app/data/.initial-admin')
[ "$perms" = "600 cloudron" ] && ok "/app/data/.initial-admin is 600 cloudron" || bad ".initial-admin perms='${perms:-missing}'"
ADMIN_PW=$(in_app 'sed -n "s/^password: //p" /app/data/.initial-admin')
if [ -n "$ADMIN_PW" ]; then
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$B/api/auth/login" \
         -H 'content-type: application/json' -d "{\"auth\":\"admin\",\"password\":\"${ADMIN_PW}\"}")
  [ "$code" = "204" ] || [ "$code" = "200" ] && ok "the seeded administrator signs in (HTTP $code)" \
    || bad "the seeded administrator could not sign in (HTTP $code)"
  "$CRI" logs "$APP" 2>&1 | grep -aqF "$ADMIN_PW" && bad "administrator password leaked into the logs" \
    || ok "administrator password is not in the logs"
else
  bad "no password in /app/data/.initial-admin"
fi

# 5. Secrets on disk are 0600 cloudron.
for f in /app/data/keys/keyring.yml /app/data/keys/cookies.env /run/semaphore/config.json; do
  perms=$(in_app "stat -c '%a %U' $f")
  [ "$perms" = "600 cloudron" ] && ok "$f is 600 cloudron" || bad "$f perms='${perms:-missing}'"
done

# 6. The server runs as cloudron, not root.
u=$(in_app 'ps -o user= -C semaphore | head -1' | tr -d ' ')
[ "$u" = "cloudron" ] && ok "semaphore runs as cloudron" || bad "semaphore runs as '${u:-unknown}' (want cloudron)"

# 7. Restart over the existing volume: keyring, cookie secrets and administrator are REUSED.
before=$(in_app 'sha256sum /app/data/keys/keyring.yml /app/data/keys/cookies.env /app/data/.initial-admin')
stop_start=$(date +%s)
"$CRI" stop -t 20 "$APP" >/dev/null 2>&1
stop_code=$("$CRI" inspect "$APP" --format '{{.State.ExitCode}}' 2>/dev/null)
stop_elapsed=$(( $(date +%s) - stop_start ))
[ "$stop_code" != "137" ] && [ "$stop_elapsed" -lt 15 ] \
  && ok "stop exits promptly, not SIGKILL (code ${stop_code}, ${stop_elapsed}s)" \
  || bad "stop was slow or SIGKILLed (code ${stop_code}, ${stop_elapsed}s)"
"$CRI" rm -f "$APP" >/dev/null 2>&1
start_app || { bad "could not restart the app container"; }
if wait_health 90; then
  after=$(in_app 'sha256sum /app/data/keys/keyring.yml /app/data/keys/cookies.env /app/data/.initial-admin')
  [ -n "$before" ] && [ "$before" = "$after" ] && ok "keyring, cookie secrets and admin file survived a restart unchanged" \
    || bad "a secret file CHANGED across a restart"
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$B/api/auth/login" \
         -H 'content-type: application/json' -d "{\"auth\":\"admin\",\"password\":\"${ADMIN_PW}\"}")
  [ "$code" = "204" ] || [ "$code" = "200" ] && ok "the administrator still signs in after a restart" \
    || bad "administrator sign-in failed after a restart (HTTP $code)"
else
  bad "did not become healthy after a restart over the existing volume"
fi

echo
echo "=== smoke result: ${fails} failure(s) ==="
[ "$fails" = 0 ] || "$CRI" logs "$APP" 2>&1 | tail -40
exit $((fails > 0 ? 1 : 0))
