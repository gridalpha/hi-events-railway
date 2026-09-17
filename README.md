# Hi.Events on Railway

A thin, production-shaped wrapper around the official
[`daveearley/hi.events-all-in-one`](https://hub.docker.com/r/daveearley/hi.events-all-in-one)
image ([Hi.Events](https://github.com/HiEventsDev/hi.events), AGPL-3.0 with additional terms)
so it deploys on Railway as a real web tier plus a real worker tier.

One image, two roles, selected by the container's argument:

| Role | Command | What it runs | Public |
|---|---|---|---|
| `web` | `/railway/entrypoint.sh web` (the image default) | nginx on `$PORT`, php-fpm, the SSR frontend | yes |
| `worker` | `/railway/entrypoint.sh worker` | the Laravel queue worker, the scheduler, a liveness server on `$PORT` | no |

## What this layer adds, and why

- **nginx binds `$PORT`.** Upstream's config hardcodes `listen 80`; the
  entrypoint renders `__PORT__` from Railway's injected value.
- **A real health check at `/healthz`.** Dot- and hyphen-free, so Railway's
  `healthcheckPath` accepts it, anonymous so the prober is not 401'd, and it
  opens the app's own Postgres and Redis connections — a deployment with a dead
  dependency fails instead of rolling out green. The worker gets the equivalent
  from a small PHP server that reports whether supervisord still has the queue
  worker `RUNNING`.
- **The real client IP.** Upstream hardcodes `TrustProxies::$proxies = '*'`,
  which Laravel reads as "trust only the calling IP". Behind Railway's edge
  *and* the image's own nginx that lands on Railway's rotating edge address, so
  every per-IP throttle — the login one included — gets a fresh bucket per
  request. This layer trusts every hop, which makes Symfony fall through to the
  leftmost `X-Forwarded-For` entry, the one the edge overwrites and a client
  cannot forge.
- **A volume-safe storage tree.** A Railway volume mounted at
  `/app/backend/storage` hides everything the image baked there, so the
  entrypoint recreates `framework/{cache,sessions,views}`, `logs` and
  `app/public` on every boot.
- **A seeded first account.** Hi.Events has no first-admin environment variable
  and no account-creation CLI — the only way in is the public registration
  endpoint. `php artisan hievents:seed-first-account` creates the owner account
  through the app's own handler before anything listens, so the deployment can
  ship with `APP_DISABLE_REGISTRATION=true` and no open signup window. It is a
  no-op once any account exists, so an operator's later changes stand.
- **One migrator.** The web role migrates with a bounded retry; the worker
  waits for the schema rather than racing it.
- **Runtime frontend config.** The SSR server injects every `VITE_*` variable
  into the page per request, so the entrypoint defaults the URL-shaped ones
  from `RAILWAY_PUBLIC_DOMAIN` and a deployer needs to set none of them.

## Environment variables

Required:

| Variable | Notes |
|---|---|
| `APP_KEY` | `base64:` + 32 bytes of base64. `base64:<43 alphanumerics>` decodes to exactly 32 bytes. |
| `JWT_SECRET` | Any long random string. |
| `DATABASE_URL` | Managed Postgres. |
| `REDIS_URL` | Managed Redis; `QUEUE_CONNECTION=redis` uses it. |
| `PORT` | Railway injects it; nginx (web) and the liveness server (worker) bind it. |

Recommended, with what this layer does if they are unset:

| Variable | Default |
|---|---|
| `APP_URL`, `APP_FRONTEND_URL`, `APP_CDN_URL` | derived from `RAILWAY_PUBLIC_DOMAIN` |
| `VITE_FRONTEND_URL`, `VITE_API_URL_CLIENT` | derived from `RAILWAY_PUBLIC_DOMAIN` |
| `VITE_APP_NAME` | `Hi.Events` |
| `ADMIN_EMAIL`, `ADMIN_PASSWORD` | first-account seed is skipped when either is empty |
| `ADMIN_FIRST_NAME`, `ADMIN_LAST_NAME`, `ADMIN_LOCALE` | `Admin`, `User`, `en` |
| `HIEVENTS_DB_WAIT_SECONDS` | `300` — how long the worker waits for the schema |

## Storage

`FILESYSTEM_PUBLIC_DISK=public` keeps uploaded event images on the web
service's volume, served by nginx at `/storage`. They deliberately do **not**
go to object storage: Hi.Events uploads them with `visibility: public`, which
makes the S3 adapter send `x-amz-acl`, and Railway's managed bucket rejects
that header outright.

Exports (`Excel::store(..., disk: 's3-private')`) are hardcoded to the
`s3-private` disk and handed to the browser as a presigned URL, so that disk
needs real S3 credentials — a Railway managed bucket, with
`AWS_USE_PATH_STYLE_ENDPOINT=true` because the bucket's CORS is path-style
only. Without it the export feature silently produces nothing.

## Upstream

Pinned to `v1.11.1-beta`, the newest full release. The image's `latest` tag
currently resolves to the same digest as `v2.0.0-rc.1`, a release candidate.
