#!/bin/sh
# Shared helpers for every role. Sourced, never executed.

HIEVENTS_ROLE="${HIEVENTS_ROLE:-web}"
BACKEND=/app/backend
HEALTH_STATE=/app/health/state

log() { echo "[hi-events/${HIEVENTS_ROLE}] $*"; }
die() { echo "[hi-events/${HIEVENTS_ROLE}] FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# APP_KEY and JWT_SECRET must be identical on the web, worker and scheduler
# services: a token minted by one is verified by the others, and APP_KEY is the
# at-rest encryption key. Neither is expressible as a Railway variable -- a
# ${{secret(N)}} reference is re-evaluated per read, so the three services would
# each get a different value -- and APP_KEY is not a plain random string but
# base64 of exactly 32 bytes. Both are therefore derived here, by every role,
# from one shared seed. Supplying APP_KEY or JWT_SECRET directly wins.
# ---------------------------------------------------------------------------
derive_secrets() {
    if [ -z "${APP_KEY:-}" ] || [ -z "${JWT_SECRET:-}" ]; then
        [ -n "${HIEVENTS_SECRET_SEED:-}" ] || die "set HIEVENTS_SECRET_SEED, or supply APP_KEY and JWT_SECRET yourself"
    fi

    if [ -z "${APP_KEY:-}" ]; then
        APP_KEY="base64:$(php -r 'echo base64_encode(hash("sha256", getenv("HIEVENTS_SECRET_SEED") . ":app_key", true));')"
        log "derived APP_KEY from HIEVENTS_SECRET_SEED"
    fi

    if [ -z "${JWT_SECRET:-}" ]; then
        JWT_SECRET="$(php -r 'echo base64_encode(hash("sha256", getenv("HIEVENTS_SECRET_SEED") . ":jwt_secret", true));')"
        log "derived JWT_SECRET from HIEVENTS_SECRET_SEED"
    fi

    export APP_KEY JWT_SECRET
}

# Railway has no service ordering, so every role waits for what it needs.
# Bounded, so a genuinely broken dependency still surfaces as a failed deploy
# rather than a container that hangs for the life of the health-check window.
wait_for() {
    what="$1"
    tries="${2:-60}"
    i=0
    while [ "$i" -lt "$tries" ]; do
        if php /app/health/check.php "$what" >/dev/null 2>&1; then
            log "$what is ready"
            return 0
        fi
        i=$((i + 1))
        sleep 5
    done
    php /app/health/check.php "$what" || true
    die "gave up waiting for $what"
}

# The volume is mounted over the image's storage tree, which takes Laravel's own
# framework directories with it. Recreate them before anything boots the
# framework, or the first artisan call dies on a missing view-cache directory.
prepare_storage() {
    mkdir -p \
        "$BACKEND/storage/app/public" \
        "$BACKEND/storage/app/private" \
        "$BACKEND/storage/framework/cache/data" \
        "$BACKEND/storage/framework/sessions" \
        "$BACKEND/storage/framework/testing" \
        "$BACKEND/storage/framework/views" \
        "$BACKEND/storage/logs" \
        "$BACKEND/bootstrap/cache"
    chown -R www-data:www-data "$BACKEND/storage" "$BACKEND/bootstrap/cache"
    chmod -R 775 "$BACKEND/storage" "$BACKEND/bootstrap/cache"
}

# The probe is answered from a file rather than from the request, because a
# Postgres and a Redis round trip can outlast the prober's own timeout.
start_health_loop() {
    mkdir -p "$HEALTH_STATE"
    rm -f "$HEALTH_STATE/ok"
    (
        while :; do
            if php /app/health/check.php all >/dev/null 2>&1; then
                : > "$HEALTH_STATE/ok"
            else
                rm -f "$HEALTH_STATE/ok"
            fi
            sleep 10
        done
    ) &
    log "health loop started"
}

# Roles with no HTTP surface of their own still get a real dependency probe, so
# a crash-looping worker cannot read SUCCESS forever.
start_health_server() {
    mkdir -p "$HEALTH_STATE"
    php -S "0.0.0.0:${PORT}" -t "$HEALTH_STATE" >/dev/null 2>&1 &
    log "health server listening on ${PORT}, path /ok"
}
