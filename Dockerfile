FROM daveearley/hi.events-all-in-one:v1.11.1-beta

# The upstream image already ends on `USER root`, but restate it so a future
# upstream change to a non-root user cannot silently break these layers.
USER root

# ---------------------------------------------------------------------------
# PHP extensions the Railway topology depends on: phpredis for the queue /
# cache connection and pdo_pgsql for the managed Postgres. Assert rather than
# assume, so a missing one fails the build in seconds instead of crash-looping
# a container.
# ---------------------------------------------------------------------------
RUN php -m | grep -qi '^redis$' || install-php-extensions redis
RUN php -r 'exit(extension_loaded("redis") && extension_loaded("pdo_pgsql") ? 0 : 1);'

# ---------------------------------------------------------------------------
# Client IP behind two proxies.
#
# Railway's edge reaches the container from 100.64.0.0/10 and sends
# `X-Forwarded-For: <client>, <edge>`; the bundled nginx then appends its own
# peer with $proxy_add_x_forwarded_for. Upstream hardcodes
# `TrustProxies::$proxies = '*'`, which Laravel resolves to "trust only the
# calling IP" (127.0.0.1, i.e. nginx), so Symfony walks the header
# right-to-left and stops on Railway's *rotating* edge address. Every per-IP
# throttle — the login one included — then gets a fresh bucket per request.
#
# Trusting every hop makes Symfony fall through to the leftmost entry, which
# the edge overwrites and a client therefore cannot forge.
# ---------------------------------------------------------------------------
RUN sed -i "s|proxies = '\*';|proxies = ['0.0.0.0/0', '::/0'];|" \
        /app/backend/app/Http/Middleware/TrustProxies.php \
 && grep -q "0.0.0.0/0" /app/backend/app/Http/Middleware/TrustProxies.php

# ---------------------------------------------------------------------------
# Railway-specific runtime files
# ---------------------------------------------------------------------------
COPY healthz.php /app/backend/public/healthz.php
COPY SeedFirstAccountCommand.php /app/backend/app/Console/Commands/SeedFirstAccountCommand.php

RUN mkdir -p /railway
COPY nginx.conf /railway/nginx.conf
COPY supervisord-web.conf /railway/supervisord-web.conf
COPY supervisord-worker.conf /railway/supervisord-worker.conf
COPY worker-health.php /railway/worker-health.php
COPY wait-for-db.php /railway/wait-for-db.php
COPY entrypoint.sh /railway/entrypoint.sh
RUN chmod +x /railway/entrypoint.sh

# The image was built with `composer install --optimize-autoloader`, so the
# console command added above needs the classmap rebuilt.
RUN composer dump-autoload --working-dir=/app/backend --no-interaction --optimize \
 && chown -R www-data:www-data /app/backend/vendor /app/backend/bootstrap/cache

# Syntax-check everything committed here: a typo then fails the build rather
# than crash-looping a container whose log shows only an exit code.
RUN sh -n /railway/entrypoint.sh \
 && php -l /app/backend/public/healthz.php \
 && php -l /app/backend/app/Console/Commands/SeedFirstAccountCommand.php \
 && php -l /railway/worker-health.php \
 && php -l /railway/wait-for-db.php \
 && python3 -c "import configparser,sys;[configparser.RawConfigParser(strict=True).read(f) for f in ['/railway/supervisord-web.conf','/railway/supervisord-worker.conf']]"

WORKDIR /app

CMD ["/railway/entrypoint.sh", "web"]
