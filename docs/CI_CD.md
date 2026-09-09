# CI/CD Pipeline

How the pipeline is built, what each gate is for, and why the choices behind it
were made. The requirement it implements is SENG 34213 §7: a GitHub Actions
pipeline by the end of Sprint 5, with the stages in §7.2 and the quality gates
in §8.2.

---

## The §7.2 stages, and where they live

| §7.2 stage          | Trigger required                 | Implemented in                        |
| ------------------- | -------------------------------- | ------------------------------------- |
| Lint & Format       | Every push, any branch           | `ci.yml` → `lint`                     |
| Build               | Every push, any branch           | `ci.yml` → `build`                    |
| Unit Tests          | Every push, any branch           | `ci.yml` → `validate` (see below)     |
| Integration Tests   | Push/PR to `develop`             | `ci.yml` → `integration`              |
| Security Scan       | Push to `develop` or `main`      | `ci.yml` → `security`, `secrets-scan` |
| Deploy — Staging    | Merge to `develop`               | `deploy-staging.yml`                  |
| Deploy — Production | Merge to `main`, manual approval | `deploy-production.yml`               |

The application's own test tiers — 1 099 Jest tests, 60 Vitest tests, 56
Playwright cases — run in the [`testing`](https://github.com/TeamNova-SRI-KO-LMS)
repository's pipeline. This repository's pipeline verifies the _infrastructure_,
and the two meet at the deployment: `deploy-staging.yml` runs the end-to-end
suite against the deployed environment after it has deployed to it.

### What replaces unit tests for infrastructure

There is no unit-test tier for a Dockerfile. What stands in for it, in
increasing order of confidence:

1. **`validate`** — every YAML file parses, every compose file resolves,
   every referenced file exists, the action satisfies the rules the Marketplace
   enforces, the scripts are syntactically valid and executable.
2. **`build`** — both images build for real, and are asserted not to run as
   root.
3. **`integration`** — the whole stack is brought up with `--wait` and
   smoke-tested through HTTP.

Stage 1 is what catches most mistakes and takes twenty seconds. Stage 3 is what
catches the ones that matter. An infrastructure change that has never been
executed has not been tested, and "the YAML parses" is not a test.

---

## The quality gates (§8.2)

| Gate                                   | Threshold | Enforced by                                          |
| -------------------------------------- | --------- | ---------------------------------------------------- |
| Zero lint errors                       | 0         | actionlint, hadolint, shellcheck, yamllint, prettier |
| No high/critical CVEs in the images    | 0 fixable | Trivy, `exit-code: 1`                                |
| No committed secrets                   | 0         | gitleaks over full history, plus `validate.js`       |
| No unpinned action references          | 0         | `validate.js`                                        |
| No image running as root               | 0         | asserted in `build`                                  |
| No high/critical dependency advisories | 0         | `npm audit`, `dependency-review`                     |

### Trivy runs twice on purpose

The first run reports everything — LOW through CRITICAL — as SARIF to the
Security tab, so findings are tracked over time and a MEDIUM that becomes a
HIGH next month is already on record.

The second run fails the build, and only on HIGH and CRITICAL **with a fix
available** (`ignore-unfixed: true`).

That last flag is the whole design. Failing on an unfixable CVE gives the team
a red build they cannot clear by any action, and the only available response is
to bypass the gate — after which the gate catches nothing. A gate must always
have a way to be satisfied, or it teaches people to route around it.

### The aggregate `pipeline` job

Branch protection points at one required check, `CI Pipeline`, which depends on
all six stages. Adding a stage does not then require reconfiguring branch
protection — which is how a newly added stage ends up non-blocking without
anyone deciding that it should be.

---

## Why the images are built from a different repository

The Dockerfiles here build from the application repository's root, because that
is where `Backend/` and `Frontend/` are. Every workflow that builds therefore
checks out both repositories.

The alternative — keeping the Dockerfiles next to the code — was rejected for a
concrete reason: a change to the base image, the hardening, or the build stages
would then be a pull request against the application repository, reviewed by
whoever is on application review, and it would be duplicated across the two
tiers. §3.1 puts Docker in the `infra` repository, and the reason holds up: it
keeps one owner for how things are built and shipped.

The cost is real and worth naming. A change to `Backend/package.json` can break
a Dockerfile that lives in another repository, and nothing in the application's
own CI will notice. That is why `ci.yml` here builds against
`APP_REPOSITORY@develop` on every push: this repository finds out.

---

## The endpoint that ties it together

`deploy-staging.yml` does three things in order, and the order is the point:

```text
publish images  →  deploy to staging  →  E2E suite against staging
     (tagged sha-<commit>)   (health + smoke)      (real TLS, real CORS, real DB)
```

The end-to-end run is against the **deployed environment**, not against a
container started inside the CI job. TLS termination, the CORS allow-list and
the managed database are the three things that differ between a compose stack
and a deployment, so they are the three that break — and if they only ever
break in Week 15, they break during the demonstration rehearsal.

---

## Concurrency

Every workflow declares a `concurrency` group. Two rules:

- **CI cancels in progress.** A second push supersedes the first; the first
  result would be discarded anyway.
- **Deployments queue.** `cancel-in-progress: false`. Cancelling a half-finished
  deployment leaves the environment in a state nobody chose — some containers
  new, some old, and a `.deployed-tag` file that no longer describes reality.

---

## Caching

`cache-from`/`cache-to: type=gha` with a per-tier `scope`. The scope matters:
without it the backend and frontend builds share one cache key and evict each
other on every run, which is slower than no cache at all.

npm dependencies use `actions/setup-node`'s built-in cache, keyed on the
lockfile.

---

## Adding a workflow

1. Declare `permissions:` explicitly and grant the minimum. A workflow with no
   `permissions` block inherits the repository default, which is broader than
   any single job needs.
2. Declare a `concurrency` group.
3. Pin every action to a release tag; a third-party action to a commit SHA.
   `@main` is remote code executing with this repository's token.
4. Start every shell step with `set -euo pipefail`. An unchecked failure in the
   middle of a deployment is worse than a failed deployment.
5. Never interpolate untrusted input — a PR title, a branch name, an issue
   body — directly into a `run:` block. Pass it through `env:` and quote it.
   This is the script-injection path, and `pull_request_target` makes it a
   privileged one.
6. Run `npm run validate` before pushing; it checks 1, 3 and the file
   references.

---

## Runtime

Roughly, on `ubuntu-latest`:

| Stage                         | Cold       | Warm       |
| ----------------------------- | ---------- | ---------- |
| Lint                          | ~50 s      | ~30 s      |
| Build (per tier, parallel)    | ~3 min     | ~40 s      |
| Validate                      | ~20 s      | ~20 s      |
| Integration                   | ~90 s      | ~90 s      |
| Security (per tier, parallel) | ~60 s      | ~45 s      |
| **Total wall clock**          | **~6 min** | **~3 min** |

Under five minutes is the number worth defending. Past that, people stop
waiting for CI before starting the next thing, and the pipeline changes from a
gate into a report.
