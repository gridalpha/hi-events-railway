#!/bin/sh
# One image, three roles. HIEVENTS_ROLE selects which one this container is.
set -eu

. /app/bin/lib.sh

derive_secrets

case "$HIEVENTS_ROLE" in
    web)       exec /app/bin/role-web.sh ;;
    worker)    exec /app/bin/role-worker.sh ;;
    scheduler) exec /app/bin/role-scheduler.sh ;;
    *)         die "unknown HIEVENTS_ROLE (expected web, worker or scheduler)" ;;
esac
