#!/bin/sh
# Creates the first account before nginx ever binds, so a public deployment has
# no window in which a stranger can claim it. A no-op once any user exists, so
# it can never revert a change the operator made later.
set -eu

. /app/bin/lib.sh

if [ -z "${HIEVENTS_ADMIN_EMAIL:-}" ] || [ -z "${HIEVENTS_ADMIN_PASSWORD:-}" ]; then
    log "no HIEVENTS_ADMIN_EMAIL / HIEVENTS_ADMIN_PASSWORD, skipping first-account seed"
    exit 0
fi

cd "$BACKEND"
php /app/bin/seed-admin.php
