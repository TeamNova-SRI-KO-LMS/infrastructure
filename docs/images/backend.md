# SRI-KO LMS — API

Express REST API for the SRI-KO Learning Management System, built for
SENG 34213 at the University of Kelaniya.

125 endpoints across authentication, courses, enrolment, progress,
subscriptions, payments, certificates, announcements, forums, notifications and
administration.

## Tags

| Tag            | Points at                                   |
| -------------- | ------------------------------------------- |
| `latest`       | The most recent release from `main`         |
| `1.2.3`        | An exact release                            |
| `1.2`, `1`     | The newest patch / minor within that line   |
| `staging`      | The current staging build from `develop`    |
| `sha-<commit>` | One exact commit — use this for deployments |

Deploy an immutable tag. A moving tag gives a rollback nothing to roll back to.

## Run it

```bash
docker run -d \
  -p 5001:5001 \
  -e MONGODB_URI="mongodb://user:password@host:27017/sriko_lms?authSource=sriko_lms" \
  -e JWT_SECRET="$(openssl rand -base64 48)" \
  -e SESSION_SECRET="$(openssl rand -base64 48)" \
  -e CORS_ORIGIN="https://your-frontend" \
  teamnova/sri-ko-lms-backend:latest
```

The full stack — API, web tier and database together — is one command:

```bash
curl -O https://raw.githubusercontent.com/TeamNova-SRI-KO-LMS/infrastructure/main/compose/docker-compose.staging.yml
docker compose -f docker-compose.staging.yml up -d --wait
```

## Configuration

| Variable           | Required | Default      | Purpose                                   |
| ------------------ | -------- | ------------ | ----------------------------------------- |
| `MONGODB_URI`      | **yes**  | —            | Connection string. Include `?authSource=` |
| `JWT_SECRET`       | **yes**  | —            | Signs access tokens                       |
| `SESSION_SECRET`   | **yes**  | —            | Signs the session cookie                  |
| `CORS_ORIGIN`      | **yes**  | —            | Allowed browser origin                    |
| `FRONTEND_URL`     | **yes**  | —            | Used in links and redirects               |
| `PORT`             | no       | `5001`       | Listen port                               |
| `NODE_ENV`         | no       | `production` |                                           |
| `JWT_EXPIRE`       | no       | `7d`         | Token lifetime                            |
| `GOOGLE_CLIENT_ID` | no       | —            | Enables Google sign-in                    |
| `LOG_LEVEL`        | no       | `info`       |                                           |

**Set `JWT_SECRET`.** Without it the application falls back to a constant
published in its own source, nothing warns you, and every token becomes
forgeable by anyone who has read the repository.

## Health

`GET /health` returns 200 when the process is up **and** the database
connection is live. It is the readiness probe; the image's own `HEALTHCHECK`
uses it.

## Image

- `node:22-alpine`, three build stages
- Runs as the unprivileged `node` user
- `dumb-init` as PID 1, so `SIGTERM` stops it immediately instead of waiting
  out the kill timeout on every deployment
- No dev dependencies, no build toolchain, no config files — configuration
  comes from the environment
- `linux/amd64` and `linux/arm64`
- Build-provenance attestation; verify with
  `gh attestation verify oci://ghcr.io/teamnova-sri-ko-lms/sri-ko-lms-backend:<tag> --owner TeamNova-SRI-KO-LMS`

## Source

<https://github.com/TeamNova-SRI-KO-LMS> — the application in
`SRI-KO_LMS_MERN`, the Dockerfile and stacks in `infrastructure`.
