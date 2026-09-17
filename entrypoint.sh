#!/bin/sh
#
# Hi.Events on Railway. One image, two roles.
#
#   web     nginx on $PORT + php-fpm + the SSR frontend  (public, has the volume)
#   worker  queue worker + scheduler + a liveness server (private, no volume)
#
# Everything here is idempotent: Railway recreates the container on every
# deploy, so each step has to tolerate already having been done.

set -e

ROLE="${1:-web}"
APP_DIR=/app/backend
PORT="${PORT:-8080}"

log() { echo "[railway] $*"; }

export PORT

log "starting role=$ROLE port=$PORT"

# ---------------------------------------------------------------------------
# Frontend configuration.
#
# The SSR server injects every VITE_* variable into the page at request time as
# window.hievents, so these are runtime config, not build config. Default them
# from the public domain Railway injects, so a template deploy needs no
# frontend variables at all and a deployer setting one still wins.
# ---------------------------------------------------------------------------
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    : "${VITE_FRONTEND_URL:=https://$RAILWAY_PUBLIC_DOMAIN}"
    : "${VITE_API_URL_CLIENT:=https://$RAILWAY_PUBLIC_DOMAIN/api}"
    : "${APP_URL:=https://$RAILWAY_PUBLIC_DOMAIN}"
    : "${APP_FRONTEND_URL:=https://$RAILWAY_PUBLIC_DOMAIN}"
    : "${APP_CDN_URL:=https://$RAILWAY_PUBLIC_DOMAIN/storage}"
fi

: "${VITE_APP_NAME:=Hi.Events}"
: "${VITE_API_URL_CLIENT:=/api}"
export VITE_FRONTEND_URL VITE_API_URL_CLIENT VITE_APP_NAME APP_URL APP_FRONTEND_URL APP_CDN_URL

if [ -z "${VITE_FRONTEND_URL:-}" ]; then
    log "WARNING: no public domain is set yet, so emailed and shared links will be relative"
fi

# ---------------------------------------------------------------------------
# Storage tree.
#
# On the web service a Railway volume is mounted at $APP_DIR/storage, which
# hides every directory the image baked there — Laravel then dies on a missing
# framework/views the moment it renders anything. Recreate the tree on every
# boot; `mkdir -p` is free when it is already there.
# ---------------------------------------------------------------------------
for dir in \
    app/public \
    app/htmlpurifier \
    framework/cache/data \
    framework/sessions \
    framework/testing \
    framework/views \
    logs
do
    mkdir -p "$APP_DIR/storage/$dir"
done

chown -R www-data:www-data "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"
chmod -R 775 "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"

cd "$APP_DIR"

# A cached config makes env() unreadable, which the seeding command below
# depends on. Clear first, and never cache.
php artisan config:clear >/dev/null 2>&1 || true
php artisan cache:clear  >/dev/null 2>&1 || true
php artisan route:clear  >/dev/null 2>&1 || true
php artisan view:clear   >/dev/null 2>&1 || true

if [ "$ROLE" = "worker" ]; then
    # ------------------------------------------------------------------
    # Worker: wait for the web service's migrations rather than racing
    # them. Railway has no dependency ordering and two `artisan migrate`
    # processes against one database is a coin toss the loser exits.
    # ------------------------------------------------------------------
    if ! php /railway/wait-for-db.php; then
        log "database never became ready; exiting so the restart policy retries"
        exit 1
    fi

    mkdir -p /railway/health-root
    cp /railway/supervisord-worker.conf /etc/supervisord.conf

    log "handing off to supervisord (worker)"
    exec /usr/bin/supervisord -c /etc/supervisord.conf
fi

# ---------------------------------------------------------------------------
# Web role
# ---------------------------------------------------------------------------

# Migrations, with a bounded retry: the managed Postgres may still be starting.
migrated=0
i=1
while [ "$i" -le 30 ]; do
    if php artisan migrate --force --no-interaction; then
        migrated=1
        break
    fi
    log "migrations failed (attempt $i) — retrying in 10s"
    i=$((i + 1))
    sleep 10
done

if [ "$migrated" -ne 1 ]; then
    log "migrations never completed; exiting so the restart policy retries"
    exit 1
fi

# The first account, created through the app's own handler before anything
# listens. No-op once an account exists, so an operator's later changes stand.
php artisan hievents:seed-first-account || log "first-account seed reported a failure (continuing)"

# public/storage -> storage/app/public, so nginx's /storage alias resolves.
php artisan storage:link >/dev/null 2>&1 || true

# nginx binds Railway's $PORT rather than the image's hardcoded 80.
sed "s/__PORT__/$PORT/g" /railway/nginx.conf > /etc/nginx/nginx.conf
nginx -t

cp /railway/supervisord-web.conf /etc/supervisord.conf

log "handing off to supervisord (web)"
exec /usr/bin/supervisord -c /etc/supervisord.conf
