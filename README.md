# SRI-KO LMS — Infrastructure

[![CI Pipeline](https://github.com/TeamNova-SRI-KO-LMS/infrastructure/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/TeamNova-SRI-KO-LMS/infrastructure/actions/workflows/ci.yml)
[![CodeQL](https://github.com/TeamNova-SRI-KO-LMS/infrastructure/actions/workflows/codeql.yml/badge.svg)](https://github.com/TeamNova-SRI-KO-LMS/infrastructure/actions/workflows/codeql.yml)
[![Deploy — Staging](https://github.com/TeamNova-SRI-KO-LMS/infrastructure/actions/workflows/deploy-staging.yml/badge.svg)](https://github.com/TeamNova-SRI-KO-LMS/infrastructure/actions/workflows/deploy-staging.yml)
[![Marketplace](https://img.shields.io/badge/marketplace-SRI--KO%20LMS%20Stack%20Deploy-blue?logo=github)](https://github.com/marketplace/actions/sri-ko-lms-stack-deploy)
[![Docker Hub](https://img.shields.io/badge/docker%20hub-sri--ko--lms-2496ED?logo=docker&logoColor=white)](https://hub.docker.com/u/teamnova)

Infrastructure as code for the **SRI-KO Learning Management System** — the
`infra` repository of SENG 34213 §3.1. Everything needed to build, ship, deploy
and roll back the application lives here: container definitions, Compose stacks
for four environments, the CI/CD pipeline, deployment scripts, and a composite
GitHub Action that other repositories call to deploy.

It contains no application code. The API and the frontend are in
[`SRI-KO_LMS_MERN`](https://github.com/TeamNova-SRI-KO-LMS); the test suites are
in [`testing`](https://github.com/TeamNova-SRI-KO-LMS); the documents are in
[`documentation`](https://github.com/TeamNova-SRI-KO-LMS).

---

## What is here

```text
.
├── action.yml                     Composite action — published to the Marketplace
├── docker/
│   ├── backend.Dockerfile         API image: 3 stages, non-root, healthcheck
│   ├── frontend.Dockerfile        Web image: build with Node, ship only nginx
│   ├── nginx/default.conf         SPA fallback, API proxy, security headers
│   └── mongo/init/01-init.js      Least-privilege app user, indexes, collections
├── compose/
│   ├── docker-compose.yml         Local development — bind-mounted, hot reload
│   ├── docker-compose.ci.yml      CI — runs the images the pipeline just built
│   ├── docker-compose.test.yml    Ephemeral stack for E2E and performance runs
│   ├── docker-compose.staging.yml Staging — pulled by tag, resource-limited
│   └── docker-compose.prod.yml    Production — read-only, no capabilities, managed DB
├── scripts/
│   ├── deploy.sh                  Deploy on the host, with health gating
│   ├── rollback.sh                Return to the previous known-good tag
│   ├── smoke-test.sh              Six checks, four seconds, run after every deploy
│   ├── backup-mongo.sh            Snapshot, verify, ship off-host, prune
│   └── validate.js                Fast local validation, no Docker needed
├── .github/workflows/             12 workflows — see below
└── docs/                          Pipeline, deployment, secrets, runbook
```

## Workflows

| Workflow                                                                   | Trigger            | Does                                                                       |
| -------------------------------------------------------------------------- | ------------------ | -------------------------------------------------------------------------- |
| [`ci.yml`](.github/workflows/ci.yml)                                       | every push, PR     | The §7.2 stages: lint, build, validate, integration, security, secret scan |
| [`codeql.yml`](.github/workflows/codeql.yml)                               | push, PR, weekly   | Static analysis of the action and the scripts                              |
| [`copilot-review.yml`](.github/workflows/copilot-review.yml)               | PR opened          | Requests a Copilot first pass; posts the human-review checklist            |
| [`dependency-review.yml`](.github/workflows/dependency-review.yml)         | PR                 | Fails on a high-severity or copyleft dependency **this PR adds**           |
| [`dependabot-auto-merge.yml`](.github/workflows/dependabot-auto-merge.yml) | Dependabot PR      | Approves and auto-merges patch/minor; flags majors for review              |
| [`dependency-updates.yml`](.github/workflows/dependency-updates.yml)       | weekly             | Audits dependencies and base images; opens an issue                        |
| [`docker-publish.yml`](.github/workflows/docker-publish.yml)               | push, tag, call    | Multi-arch images to Docker Hub and GHCR, with provenance                  |
| [`release.yml`](.github/workflows/release.yml)                             | `v*.*.*` tag       | Validates SemVer and the changelog, publishes images, creates the release  |
| [`publish-packages.yml`](.github/workflows/publish-packages.yml)           | release            | npm package and container images to GitHub Packages                        |
| [`publish-marketplace.yml`](.github/workflows/publish-marketplace.yml)     | release            | Validates and tests the action, moves the major tag                        |
| [`deploy-staging.yml`](.github/workflows/deploy-staging.yml)               | merge to `develop` | Auto-deploys, smoke-tests, then runs E2E against staging                   |
| [`deploy-production.yml`](.github/workflows/deploy-production.yml)         | `v*.*.*` tag       | Pre-flight, backup, **manual approval**, deploy, watch for 10 min          |

Full description of each stage and gate: [docs/CI_CD.md](docs/CI_CD.md).

---

## Usage

The composite action in this repository deploys the SRI-KO LMS stack to a
remote Docker host over SSH. It waits for every container to report healthy,
smoke-tests the deployment, and **rolls back to the previous image tag
automatically** if either check fails.

```yaml
name: Deploy

on:
  push:
    branches: [develop]

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: staging
      url: ${{ vars.STAGING_URL }}
    steps:
      - uses: actions/checkout@v6

      - name: Deploy the stack
        id: deploy
        uses: TeamNova-SRI-KO-LMS/infrastructure@v1
        with:
          host: ${{ secrets.STAGING_HOST }}
          user: ${{ secrets.STAGING_USER }}
          ssh-private-key: ${{ secrets.STAGING_SSH_KEY }}
          environment: staging
          image-tag: sha-${{ github.sha }}
          env-file: ${{ secrets.STAGING_ENV_FILE }}
          smoke-test-url: ${{ vars.STAGING_URL }}

      - name: Report
        run: |
          echo "Status:   ${{ steps.deploy.outputs.status }}"
          echo "Deployed: ${{ steps.deploy.outputs.deployed-tag }}"
          echo "Previous: ${{ steps.deploy.outputs.previous-tag }}"
```

### Why the rollback matters

A deploy step that pushes a new tag and stops has a failure mode where the
environment is left broken and somebody has to log in and fix it by hand, at
whatever hour it happened. Recording the tag that was running, and putting it
back when the health check says the new one is not serving, turns that into a
red build and an environment that is still up.

`§9.1` makes this concrete for this project: an unresolved live failure during
the final demonstration is a failed demonstration.

## Inputs

| Input                 | Required | Default                              | Description                                               |
| --------------------- | -------- | ------------------------------------ | --------------------------------------------------------- |
| `host`                | **yes**  | —                                    | Hostname or IP of the target Docker host                  |
| `user`                | no       | `deploy`                             | SSH user on the host                                      |
| `ssh-private-key`     | **yes**  | —                                    | SSH private key. Pass a secret, never a literal           |
| `ssh-port`            | no       | `22`                                 | SSH port                                                  |
| `environment`         | no       | `staging`                            | `staging` or `production`                                 |
| `compose-file`        | no       | `compose/docker-compose.staging.yml` | Stack to deploy                                           |
| `remote-path`         | no       | `/opt/sri-ko-lms`                    | Directory on the host holding the stack                   |
| `image-tag`           | **yes**  | —                                    | Tag to deploy. Use an immutable tag                       |
| `backend-image`       | no       | `teamnova/sri-ko-lms-backend`        | Backend image repository                                  |
| `frontend-image`      | no       | `teamnova/sri-ko-lms-frontend`       | Frontend image repository                                 |
| `env-file`            | no       | `""`                                 | Base64-encoded `.env`; written with mode 600              |
| `health-timeout`      | no       | `180`                                | Seconds to wait for every container to be healthy         |
| `smoke-test-url`      | no       | `""`                                 | Public URL of the web tier; enables the smoke test        |
| `smoke-test-api-url`  | no       | `""`                                 | Public API URL; defaults to `<smoke-test-url>/api`        |
| `rollback-on-failure` | no       | `true`                               | Restore the previous tag if a check fails                 |
| `prune`               | no       | `true`                               | Remove images older than a week after a successful deploy |

> **`image-tag` should be immutable** — a version (`1.2.3`) or a commit tag
> (`sha-abc123`). The action refuses `latest`, `main`, `master` and `develop`
> for production and warns elsewhere, because a moving tag gives a rollback
> nothing to roll back _to_: it points somewhere else by the time anyone tries.

## Outputs

| Output         | Description                                            |
| -------------- | ------------------------------------------------------ |
| `deployed-tag` | The image tag now running                              |
| `previous-tag` | The tag that was running before, for a manual rollback |
| `status`       | `success`, `rolled-back`, or `failed`                  |
| `duration`     | Deployment duration in seconds                         |

---

## Quick start

### Prerequisites

| Requirement                | Version | Notes                                                    |
| -------------------------- | ------- | -------------------------------------------------------- |
| Docker Engine              | ≥ 24    | With Compose v2 (`docker compose`, not `docker-compose`) |
| Node.js                    | ≥ 18.18 | Only for `npm run validate` and the formatter            |
| The application repository | —       | Checked out alongside; see `APP_PATH` in `.env.example`  |

### Which application repository?

The organisation has two, with different directory casing, and every build path
here supports both:

| Repository        | Layout                  | Build arguments                             |
| ----------------- | ----------------------- | ------------------------------------------- |
| `SRI-KO_LMS_MERN` | `Backend/`, `Frontend/` | none — this is the default                  |
| `app`             | `backend/`, `frontend/` | `BACKEND_DIR=backend FRONTEND_DIR=frontend` |

In CI the two are repository variables, `APP_BACKEND_DIR` and
`APP_FRONTEND_DIR`; locally they are environment variables read by the compose
files. Hard-coding either casing makes the Dockerfile silently wrong for the
other, and the resulting error — "package.json not found" — gives no hint which
of the two you are looking at.

### Building an image by hand

The frontend image needs the nginx config, which lives **here** while the build
context is the **application** repository. `--build-context` supplies it as a
second named context:

```bash
export APP_PATH=../../SRI-KO_Application_Project/SRI-KO_LMS_MERN

npm run build:backend
npm run build:frontend      # passes --build-context infra=. for you
```

A build that omits it fails immediately with `failed to resolve context: infra`,
which is a legible error rather than a container quietly serving the stock nginx
welcome page.

### Run the whole stack locally

```bash
git clone https://github.com/TeamNova-SRI-KO-LMS/infrastructure.git
cd infrastructure

cp .env.example .env
# Fill in the three secrets. Generate each with:
#   openssl rand -base64 48

npm install                 # for the validation script
npm run validate            # parses everything, no Docker needed

docker compose -f compose/docker-compose.yml up -d --wait
./scripts/smoke-test.sh http://localhost:5173 http://localhost:5001
```

The web tier is on <http://localhost:5173>, the API on <http://localhost:5001>,
and MongoDB on `localhost:27017`.

```bash
docker compose -f compose/docker-compose.yml logs -f
docker compose -f compose/docker-compose.yml down -v   # -v also drops the data
```

### Deploy by hand

The workflows are the normal path. This is the one for when GitHub Actions is
down, or the demonstration is in ninety minutes:

```bash
ssh deploy@staging-host
cd /opt/sri-ko-lms
IMAGE_TAG=1.2.3 ./scripts/deploy.sh staging
./scripts/rollback.sh staging          # if it goes wrong
```

---

## Environments

| Environment | Stack                        | Deployed by                        | Database                |
| ----------- | ---------------------------- | ---------------------------------- | ----------------------- |
| Local       | `docker-compose.yml`         | `docker compose up`                | Container, named volume |
| CI          | `docker-compose.ci.yml`      | `ci.yml`                           | Container, tmpfs        |
| Test        | `docker-compose.test.yml`    | E2E and performance runs           | Container, tmpfs        |
| Staging     | `docker-compose.staging.yml` | Merge to `develop`, automatic      | Container, named volume |
| Production  | `docker-compose.prod.yml`    | Tag on `main`, **manual approval** | Managed MongoDB         |

Production differs in more than scale: every container is read-only, drops all
Linux capabilities, and cannot gain privileges; there is no database container,
because a compose-managed MongoDB has no replica set, no backups and no
monitoring. Details in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Secrets

Nothing in this repository contains a credential, and nothing ever should —
§7 is unconditional, including for private repositories. What each secret is
for, which environment needs it, and how to rotate one:
[docs/SECRETS.md](docs/SECRETS.md).

The CI pipeline enforces it: `gitleaks` scans the full history on every push,
and `npm run validate` refuses a literal AWS key, GitHub token, private key or
MongoDB password anywhere in the tree.

## When something breaks

[docs/RUNBOOK.md](docs/RUNBOOK.md) — first response for a failed deployment, a
site that is down, a database that will not connect, a disk that is full, and
the known limitations that will eventually cause an incident.

---

## Standards

The same as every other repository in the organisation:
[coding standards](https://github.com/TeamNova-SRI-KO-LMS/documentation/blob/main/documents/standards/coding-standards.md),
[git workflow](https://github.com/TeamNova-SRI-KO-LMS/documentation/blob/main/documents/standards/git-workflow.md),
[code review](https://github.com/TeamNova-SRI-KO-LMS/documentation/blob/main/documents/standards/code-review-standards.md),
[Definition of Done](https://github.com/TeamNova-SRI-KO-LMS/documentation/blob/main/documents/standards/definition-of-done.md).

Branch from `develop`, Conventional Commits, one approving review, `npm run
verify` green before opening the pull request.

## Licence

Coursework produced for SENG 34213 at the University of Kelaniya. Not licensed
for redistribution — see [LICENSE](LICENSE).
