#!/bin/sh
# Build-time patches to the published hi.events all-in-one image.
# Every edit is followed by an assertion so an upstream rename fails the build.
set -eu

say() { echo "[patch-image] $*"; }

# ---------------------------------------------------------------------------
# 1. Trusted proxies
#
# Railway's edge reaches the container from 100.64.0.0/10 and appends its own
# rotating 152.233.0.0/17 address to X-Forwarded-For, so the header arrives as
# "<real client>, <edge>". hi.events hardcodes Laravel's $proxies = '*', which
# trusts only the calling IP and makes Symfony walk the header right to left --
# it stops on the edge entry, so request()->ip() is a different address on every
# request and Laravel's per-IP throttles never bucket. $proxies is truthy, so
# config('trustedproxy.proxies') is never consulted and no variable can fix it.
# ---------------------------------------------------------------------------
TRUST=/app/backend/app/Http/Middleware/TrustProxies.php
NEW="protected \$proxies = ['100.64.0.0/10', '152.233.0.0/17', 'fd00::/8', '127.0.0.1', '::1'];"
grep -q "protected \$proxies = '\*';" "$TRUST"
sed -i "s|protected \$proxies = '\*';|${NEW}|" "$TRUST"
grep -q "100.64.0.0/10" "$TRUST"
php -l "$TRUST" >/dev/null
say "trusted proxies set to Railway edge ranges"

# ---------------------------------------------------------------------------
# 2. Supervisor programs
#
# The published image runs nginx, php-fpm, the SSR server, a queue worker and a
# scheduler in one container. Here the worker and the scheduler are their own
# Railway services, so both programs are dropped: a schedule:run loop in two
# containers fires every scheduled job twice.
# ---------------------------------------------------------------------------
SUP=/etc/supervisord.conf
awk '
  /^\[program:/ { drop = ($0 ~ /^\[program:(laravel-queue-worker|laravel-scheduler)\]/) }
  !drop
' "$SUP" > "$SUP.new"
mv "$SUP.new" "$SUP"
[ "$(grep -c '^\[program:' "$SUP")" = "3" ]
grep -q '^\[program:nginx\]' "$SUP"
grep -q '^\[program:php-fpm\]' "$SUP"
grep -q '^\[program:nodejs\]' "$SUP"
! grep -q 'laravel-queue-worker\|laravel-scheduler' "$SUP"
say "supervisord reduced to nginx, php-fpm and the SSR server"

# ---------------------------------------------------------------------------
# 3. Health route
#
# The app exposes no anonymous route that touches its dependencies: "/" is the
# SSR app and every API route is authenticated. Serve a marker file that a
# background loop in the entrypoint refreshes, so the probe reports Postgres,
# Redis and the SSR server without doing any of that work inside the request.
# ---------------------------------------------------------------------------
NGINX=/etc/nginx/nginx.conf
grep -q 'server_name _;' "$NGINX"
sed -i 's|server_name _;|server_name _;\n\n       location = /healthz {\n           root /app/health/state;\n           default_type text/plain;\n           try_files /ok =503;\n           access_log off;\n       }|' "$NGINX"
grep -q 'location = /healthz' "$NGINX"
mkdir -p /app/health/state
nginx -t
say "added an anonymous /healthz route"

say "done"
