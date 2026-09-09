# SRI-KO LMS — Web

React single-page frontend for the SRI-KO Learning Management System, built for
SENG 34213 at the University of Kelaniya.

Served by nginx as a static bundle. Node is present only in the build stage, so
the image that faces the internet has no JavaScript runtime in it at all.

## Tags

| Tag            | Points at                                   |
| -------------- | ------------------------------------------- |
| `latest`       | The most recent release from `main`         |
| `1.2.3`        | An exact release                            |
| `1.2`, `1`     | The newest patch / minor within that line   |
| `staging`      | The current staging build from `develop`    |
| `sha-<commit>` | One exact commit — use this for deployments |

## Run it

```bash
docker run -d -p 8080:8080 teamnova/sri-ko-lms-frontend:latest
```

Listens on **8080**, not 80: the container runs unprivileged and cannot bind a
port below 1024.

## Configuration

Vite inlines its configuration at **build** time, so these are build arguments
rather than runtime environment variables. A published image already has its
API URL baked in.

| Build argument          | Default                             | Purpose                           |
| ----------------------- | ----------------------------------- | --------------------------------- |
| `VITE_API_URL`          | `/api`                              | Where the browser sends API calls |
| `VITE_GOOGLE_CLIENT_ID` | —                                   | Public OAuth client id            |
| `VITE_APP_NAME`         | `SRI-KO Learning Management System` |                                   |
| `VITE_NODE_ENV`         | `production`                        |                                   |

```bash
docker build \
  -f infrastructure/docker/frontend.Dockerfile \
  --build-arg VITE_API_URL=https://api.example.com/api \
  -t sri-ko-lms-frontend .
```

Only public values belong here. Anything passed as a `VITE_*` build argument is
shipped to every browser in the JavaScript bundle.

The default `/api` assumes the API is reachable on the same origin — which the
bundled nginx config arranges, by proxying `/api/` to a service named `api`.
That removes CORS from the picture entirely.

## Health

`GET /healthz` returns `ok`. Separate from `/`, so a load balancer probe does
not pull the whole SPA on every check, and so a probe cannot be satisfied by
the SPA fallback returning `index.html` for a broken path.

## Image

- Multi-stage: `node:22-alpine` builds, `nginxinc/nginx-unprivileged` serves
- Runs as uid 101; no root process in the container
- SPA fallback (`try_files … /index.html`), so deep links and page refreshes
  work
- Content-hashed assets cached for a year; `index.html` never cached
- Security headers: `X-Frame-Options`, `X-Content-Type-Options`,
  `Referrer-Policy`, `Permissions-Policy`, `Strict-Transport-Security`
- gzip on text responses; dotfiles denied
- `linux/amd64` and `linux/arm64`
- Build-provenance attestation

No Content-Security-Policy is set in the image: the correct policy depends on
the third-party origins a given deployment uses, and a CSP that is wrong breaks
the page in a way nobody notices until a user reports it. Set it at the edge,
report-only first.

## Source

<https://github.com/TeamNova-SRI-KO-LMS> — the application in
`SRI-KO_LMS_MERN`, the Dockerfile and stacks in `infrastructure`.
