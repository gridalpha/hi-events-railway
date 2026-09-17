#!/bin/sh
# nginx + php-fpm (the API) + the SSR frontend, all on one origin. This role is
# also the elected migrator: the worker and the scheduler wait for it.
set -eu

. /app/bin/lib.sh

: "${PORT:=80}"

# The image's supervisord interpolates four VITE_ names into the SSR server's
# environment and refuses to start at all if any of them is merely absent --
# "Format string ... contains names which cannot be expanded". Railway never
# injects a variable whose value is the empty string, so an optional one such as
# the Stripe publishable key has to be materialised here.
export VITE_API_URL_CLIENT="${VITE_API_URL_CLIENT:-http://localhost:${PORT}/api}"
export VITE_API_URL_SERVER="${VITE_API_URL_SERVER:-http://localhost:${PORT}/api}"
export VITE_FRONTEND_URL="${VITE_FRONTEND_URL:-http://localhost:${PORT}}"
export VITE_STRIPE_PUBLISHABLE_KEY="${VITE_STRIPE_PUBLISHABLE_KEY:-}"

prepare_storage
wait_for db

cd "$BACKEND"

log "running migrations"
php artisan migrate --force --no-interaction

# Never config:cache here: Url::getCdnUrl reads env('APP_CDN_URL') directly, and
# a cached config makes every env() call return null.
php artisan cache:clear || true
php artisan config:clear
php artisan route:clear
php artisan view:clear
php artisan storage:link

/app/bin/seed-admin.sh

prepare_storage
start_health_loop

nginx -t
log "starting supervisord"
exec /usr/bin/supervisord -c /etc/supervisord.conf
