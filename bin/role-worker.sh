#!/bin/sh
# The queue tier. Handles order confirmation e-mail, webhook delivery, exports,
# waitlist offers and the event statistics rollups.
set -eu

. /app/bin/lib.sh

: "${PORT:=8080}"

wait_for db
wait_for migrations

start_health_loop
start_health_server

cd "$BACKEND"
log "starting queue worker"
exec php artisan queue:work \
    --queue="${HIEVENTS_QUEUES:-default,webhook-queue}" \
    --sleep="${HIEVENTS_QUEUE_SLEEP:-3}" \
    --tries="${HIEVENTS_QUEUE_TRIES:-3}" \
    --timeout="${HIEVENTS_QUEUE_TIMEOUT:-60}" \
    --no-interaction
