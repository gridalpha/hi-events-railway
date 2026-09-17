# hi.events on Railway

A thin wrapper around the published [hi.events](https://github.com/HiEventsDev/hi.events)
all-in-one image that makes it deployable on Railway as a scaled topology: a web
tier, a queue worker and a scheduler, all built from this one image.

```
FROM daveearley/hi.events-all-in-one:v1.11.1-beta
```

## Why this repo exists

The published image is a single container running nginx, php-fpm, the SSR
frontend, a queue worker and a scheduler under supervisord. Four things cannot be
expressed as Railway variables, and each of them is handled here:

| Gap | Fix |
|---|---|
| `APP_KEY` is base64 of exactly 32 bytes and `JWT_SECRET` must match across three services | both derived from one `HIEVENTS_SECRET_SEED`, identically, by every role |
| Laravel's trusted-proxy list is hardcoded to `'*'`, which lands on Railway's rotating edge address and breaks every per-IP throttle | patched to Railway's edge ranges at build time, with an assertion |
| The worker and scheduler are bundled into the web container, so a second replica would run two schedulers | both supervisord programs are stripped; each is its own Railway service |
| Registration is open on first boot, and the app has no anonymous route that touches its dependencies | the first account is seeded before nginx binds, and a `/healthz` route reports Postgres, Redis and the SSR server |

## Roles

`HIEVENTS_ROLE` selects what a container is. One image, three services.

| Role | Runs | Public | Volume |
|---|---|---|---|
| `web` | nginx + php-fpm + the SSR frontend; also the elected migrator | yes | `/app/backend/storage` |
| `worker` | `queue:work` over `default` and `webhook-queue` | no | no |
| `scheduler` | `schedule:run` every 60s | no | no |

The worker and the scheduler wait for the web tier's migrations before starting.

## Variables

| Variable | Notes |
|---|---|
| `HIEVENTS_SECRET_SEED` | required; `APP_KEY` and `JWT_SECRET` are derived from it. Set `APP_KEY` / `JWT_SECRET` directly to override |
| `HIEVENTS_ROLE` | `web`, `worker` or `scheduler` |
| `HIEVENTS_ADMIN_EMAIL`, `HIEVENTS_ADMIN_PASSWORD` | seed the first account on an empty database; ignored once any user exists |
| `DATABASE_URL`, `REDIS_URL` | Postgres and Redis |
| `PORT` | `80` on the web role (nginx), anything on the others (the health server) |

Everything else is hi.events' own configuration, documented at
<https://hi.events/docs/getting-started/deploying>.

## Health

`/healthz` on the web role and `/ok` on the others are served from a marker file
that a background loop refreshes every ten seconds, because a Postgres plus a
Redis round trip can outlast the prober's own timeout.

## Licence

hi.events is AGPL-3.0. This wrapper adds no application code.
