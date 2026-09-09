# Deployment

How the SRI-KO LMS gets from a merge to a running environment, how to do it by
hand when that path is unavailable, and how to undo it.

---

## Topology

```text
                          ┌──────────────────────────┐
      Browser  ─── TLS ──►│  Reverse proxy / CDN     │  TLS terminates here
                          └────────────┬─────────────┘
                                       │ HTTP
                          ┌────────────▼─────────────┐
                          │  web  (nginx, port 8080) │  static bundle + /api proxy
                          └────────────┬─────────────┘
                                       │ HTTP
                          ┌────────────▼─────────────┐
                          │  api  (node, port 5001)  │  Express, stateless
                          └────────────┬─────────────┘
                                       │ TLS
                          ┌────────────▼─────────────┐
                          │  MongoDB                 │  container (staging)
                          │                          │  managed  (production)
                          └──────────────────────────┘
```

The API holds no session state, so more replicas need no shared session store —
which is the property [ADR-001](https://github.com/TeamNova-SRI-KO-LMS/documentation/blob/main/documents/adr/ADR-001-stateless-jwt-authentication.md)
bought, and the reason logout cannot invalidate a token server-side.

TLS terminates at the edge, not in the containers. `HTTPS_ENABLE` stays `false`
inside the stack, and the API trusts `X-Forwarded-Proto` for its redirect
decision.

## Environments

|                  | Local                | CI                      | Staging                      | Production                |
| ---------------- | -------------------- | ----------------------- | ---------------------------- | ------------------------- |
| Stack            | `docker-compose.yml` | `docker-compose.ci.yml` | `docker-compose.staging.yml` | `docker-compose.prod.yml` |
| Images           | built                | built by the pipeline   | pulled by tag                | pulled by tag             |
| Database         | container, volume    | container, tmpfs        | container, volume            | **managed**               |
| Deployed by      | a person             | `ci.yml`                | merge to `develop`           | tag on `main` + approval  |
| Restart policy   | `unless-stopped`     | none                    | `unless-stopped`             | `always`                  |
| Read-only rootfs | no                   | no                      | no                           | **yes**                   |
| Capabilities     | default              | default                 | default                      | **all dropped**           |
| Replicas         | 1                    | 1                       | 1                            | 2                         |
| Resource limits  | none                 | none                    | yes                          | yes                       |

### Why production has no database container

A MongoDB in a compose file on one host has no replica set, so no failover; no
scheduled backup; no point-in-time recovery; and its data lives on the same disk
as the thing most likely to fill it. It is fine for staging, where the worst
case is re-seeding demo data.

Production points `MONGODB_URI` at managed MongoDB. `scripts/backup-mongo.sh`
still runs before every deployment, because a managed backup you have never
restored from is a backup you are guessing about.

### Why production is read-only

`read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`. The API writes to
exactly one path — `/app/uploads` — and nginx to its cache and run directories;
those are a volume and tmpfs mounts. Everything else that tries to write fails.

That is the point: a process that has been compromised usually wants to write
something, and a container that cannot write anywhere it was not explicitly
allowed to is a much smaller foothold. It also surfaces accidental writes —
a temp file in the working directory, a log written beside the source — as an
error in staging rather than as unbounded disk growth in production.

---

## Automatic deployment

### Staging — on every merge to `develop`

```text
merge  →  build & push images (sha-<commit>)
       →  upload the stack definition over SSH
       →  docker compose pull && up -d --wait
       →  smoke test (6 checks)
       →  record .deployed-tag
       →  Playwright E2E against the deployed URL
```

Failure at the health check or the smoke test rolls back to the previously
recorded tag automatically, and the failed deployment's logs are uploaded as a
workflow artefact before the rollback destroys them.

### Production — on a version tag, after approval

```text
tag v1.2.3  →  pre-flight  (SemVer, tag on main, release exists, images in registry)
            →  backup      (mongodump, verified, shipped off-host)
            →  ⏸ MANUAL APPROVAL  (production environment reviewers)
            →  deploy      (pull, up --wait, smoke test)
            →  verify      (20 checks over 10 minutes)
```

Everything that can fail runs **before** the approval, so the approver is
deciding about a release that has already been verified rather than about a
hope. The backup runs before the gate for the same reason: a restore point
created after the decision is created too late.

The approval itself is not in the workflow file. It comes from the `production`
GitHub Environment having required reviewers — which means it cannot be removed
in a pull request by whoever wants to skip it.

#### Setting up the approval gate

**Settings → Environments → New environment → `production`**

- Required reviewers: the team lead and one other
- Wait timer: 0 — the reviewer is the delay
- Deployment branches: _Protected branches only_

Repeat for `production-backup` with no reviewers, so the snapshot runs
unattended.

### Why the ten-minute watch

The failures that matter in production are rarely visible in the first thirty
seconds: a memory leak, a connection pool that fills, a container that restarts
once and then again. Twenty checks over ten minutes, tolerating two failures,
distinguishes "deployed" from "still up".

---

## Manual deployment

The workflows are the normal path. This is for when GitHub Actions is
unavailable, or the demonstration is in ninety minutes and nobody has time to
debug a pipeline.

```bash
ssh deploy@staging-host
cd /opt/sri-ko-lms

# Deploy a specific version
IMAGE_TAG=1.2.3 ./scripts/deploy.sh staging

# Or production, with the smoke test wired in
SMOKE_TEST_URL=https://sri-ko-lms.example \
IMAGE_TAG=1.2.3 ./scripts/deploy.sh production
```

`deploy.sh` refuses to start if the disk has under 2 GB free, validates the
compose configuration before pulling, pulls before stopping anything, waits on
the healthchecks, and records the tag only after everything passed — so the
recorded tag is always one that was observed working.

### Rolling back

```bash
./scripts/rollback.sh staging            # to the previous recorded tag
./scripts/rollback.sh production 1.1.4   # to a specific one
```

It captures the current logs before replacing anything. The rollback destroys
the evidence of why the rollback was needed, and that evidence is what stops it
happening again next week.

> A rollback restores service. It does not fix anything. The script says so
> when it finishes, and the three steps it lists — read the log, open an issue,
> write the test that would have caught it — are the actual work.

---

## Host preparation

A fresh Ubuntu host, once:

```bash
# Docker Engine with the Compose plugin
curl -fsSL https://get.docker.com | sh

# An unprivileged deployment user
sudo useradd -m -s /bin/bash deploy
sudo usermod -aG docker deploy

# Its key. Generate the pair locally; the private half becomes the
# STAGING_SSH_KEY / PRODUCTION_SSH_KEY secret and never touches the host.
sudo -u deploy mkdir -p /home/deploy/.ssh
sudo -u deploy chmod 700 /home/deploy/.ssh
# append the public key to /home/deploy/.ssh/authorized_keys

# The stack directory
sudo mkdir -p /opt/sri-ko-lms/{scripts,backups,docker}
sudo chown -R deploy:deploy /opt/sri-ko-lms

# The environment file. Never committed; mode 600.
sudo -u deploy touch /opt/sri-ko-lms/.env
sudo -u deploy chmod 600 /opt/sri-ko-lms/.env
```

Then, on the host, put the reverse proxy in front. Caddy is two lines and
handles certificates automatically:

```text
sri-ko-lms.example {
    reverse_proxy localhost:8080
}
```

### Log rotation

The compose stacks set `max-size` and `max-file` on the json-file driver. Do
not remove them: an unrotated Docker log has filled more staging disks than any
application bug, and it fills them silently until the database cannot write.

---

## Verifying a deployment

```bash
./scripts/smoke-test.sh https://staging.example https://api.staging.example
```

Six checks, four seconds: the API health endpoint, a real read through
Mongoose, a protected route returning 401, the web health endpoint, the SPA
document, and the SPA fallback on a deep link.

The third and the sixth are the ones worth understanding.

**The 401 check** catches a deployment that shipped without its auth
middleware — which is invisible to any check that only looks for 200s, and has
happened to other people.

**The SPA fallback check** catches a broken `try_files`, which breaks every deep
link and every page refresh while the home page still works perfectly. That is
the deployment that looks fine to whoever tests it by visiting `/`.

---

## Known limitations

Recorded here because each will eventually cause an incident, and the person
handling it should not have to rediscover them.

| Limitation                                | Effect                                                               | Fix                                                                                 |
| ----------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Uploads are on a local volume             | Two API replicas cannot see each other's uploaded files              | Object storage (S3 or compatible)                                                   |
| No shared cache                           | Every request hits the database                                      | Redis in front of the catalogue                                                     |
| Single host                               | The host is the single point of failure                              | Managed container platform, or a second host behind the proxy                       |
| Health checks are shallow                 | `/health` checks the DB connection, not that queries succeed         | A deeper readiness probe                                                            |
| No CSP header                             | Clickjacking and injection defences are weaker than they could be    | Set it at the edge, report-only first — see the note in `docker/nginx/default.conf` |
| Rollback does not migrate the schema back | A deploy that changed the schema cannot be undone by image tag alone | Reversible migrations, or forward-only fixes                                        |

The last one is the one to remember. `rollback.sh` restores the _images_. If a
release changed the shape of the data, restoring the previous image leaves the
old code reading new documents. That is what the pre-deployment backup is for,
and why a schema change's pull request must state its rollback plan
(Definition of Done, "A schema change").
