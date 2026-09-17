#!/bin/sh
# Laravel's scheduler. Single instance by design -- schedule:run has no leader
# election, so two containers would fire every scheduled job twice.
set -eu

. /app/bin/lib.sh

: "${PORT:=8080}"

trap 'exit 0' INT TERM

wait_for db
wait_for migrations

start_health_loop
start_health_server

cd "$BACKEND"
log "starting scheduler loop"
while :; do
    php artisan schedule:run --no-interaction || log "schedule:run exited non-zero, retrying next tick"
    sleep 60
done
