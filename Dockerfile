FROM daveearley/hi.events-all-in-one:v1.11.1-beta

# The base image already ends on root; restate it so the build steps below cannot
# inherit a non-root USER if upstream ever adds one.
USER root

COPY bin/ /app/bin/
COPY health/ /app/health/

# Fail the build, not a container, on a typo in anything committed here.
RUN set -eu; \
    for f in /app/bin/*.sh; do sh -n "$f"; done; \
    for f in /app/bin/*.php /app/health/*.php; do php -l "$f" >/dev/null; done; \
    chmod +x /app/bin/*.sh

# Patches the published image in place: Laravel's hardcoded trusted-proxy list,
# the supervisor programs that become their own Railway services, and an
# anonymous /healthz route. Every patch asserts itself, so an upstream rename
# fails the build instead of the deployment.
RUN /app/bin/patch-image.sh

WORKDIR /app

CMD ["/app/bin/entrypoint.sh"]
