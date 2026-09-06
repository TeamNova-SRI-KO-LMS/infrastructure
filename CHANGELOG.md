# Changelog

All notable changes to the infrastructure.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/) (§3.3), tracking the
application release it deploys.

## [Unreleased]

Nothing yet.

## [1.0.0] — 2026-09-05

Sprint 8 — Quality & Release. The first complete infrastructure set.

### Added

**Containers**

- `docker/backend.Dockerfile` — three stages, non-root, `dumb-init` as PID 1,
  a `/health` healthcheck, and configuration files stripped from the runtime
  image so no credential can be baked in.
- `docker/frontend.Dockerfile` — Node builds, `nginx-unprivileged` serves; no
  JavaScript runtime in the shipped image.
- `docker/nginx/default.conf` — SPA fallback, `/api` proxy, immutable caching
  for hashed assets, no caching for `index.html`, five security headers.
- `docker/mongo/init/01-init.js` — least-privilege application user, the twelve
  collections, and the uniqueness indexes created before the application
  connects.

**Compose stacks**

- Development, CI, ephemeral test, staging and production.
- Production is read-only with all capabilities dropped, runs two replicas with
  `start-first` updates and rollback on failure, and has no database container —
  it points at managed MongoDB.

**Workflows** (12)

- `ci.yml` — the §7.2 stages: lint (actionlint, hadolint, shellcheck, yamllint,
  prettier), build both images, validate compose and the action, boot the stack
  and smoke-test it, Trivy on the built images, gitleaks over full history, and
  an aggregate `pipeline` gate for branch protection.
- `codeql.yml` — static analysis of the action and the scripts, weekly and on
  every push.
- `copilot-review.yml` — requests a Copilot first pass and posts the human
  review checklist. Does not satisfy §5.3 on its own, and says so.
- `dependency-review.yml` — fails on a high-severity or copyleft dependency the
  pull request adds.
- `dependabot-auto-merge.yml` — approves and auto-merges patch and minor
  updates; labels majors for review with a checklist.
- `dependency-updates.yml` — weekly audit of dependencies and base images,
  reported as an issue.
- `docker-publish.yml` — multi-arch images to Docker Hub and GHCR, with SBOM
  and build-provenance attestation. Callable from other repositories.
- `release.yml` — validates SemVer, requires a changelog entry, requires the
  tag to be on `main`, publishes images, creates the release with a deployment
  bundle attached.
- `publish-packages.yml` — npm package and container images to GitHub Packages,
  with the package contents asserted before publish.
- `publish-marketplace.yml` — validates the action against the Marketplace
  rules, proves it runs, moves the major version tag.
- `deploy-staging.yml` — automatic on merge to `develop`, then the Playwright
  suite against the deployed environment.
- `deploy-production.yml` — pre-flight checks, database snapshot, manual
  approval through environment protection, deploy, then ten minutes of
  verification.

**Action**

- `action.yml` — _SRI-KO LMS Stack Deploy_: deploys over SSH, waits for health,
  smoke-tests, and rolls back to the previous tag automatically on failure.
  16 inputs, 4 outputs. Refuses a moving image tag in production.

**Scripts**

- `deploy.sh` — disk check, config validation, pull before stop, health gating,
  and the deployed tag recorded only after everything passed.
- `rollback.sh` — captures the logs before replacing anything, then returns to
  the last known-good tag.
- `smoke-test.sh` — six checks in four seconds, including a 401 assertion and
  an SPA-fallback assertion.
- `backup-mongo.sh` — dump, verify the archive, ship off-host, prune, and print
  the restore command.
- `validate.js` — 179 checks with no Docker required.

**Documentation**

- `docs/CI_CD.md`, `docs/DEPLOYMENT.md`, `docs/SECRETS.md`, `docs/RUNBOOK.md`,
  and Docker Hub descriptions for both images.

### Security

- No secret is committed; six independent controls enforce it.
- Both images run as a non-root user, asserted in CI rather than assumed.
- Trivy gates on fixable HIGH and CRITICAL findings only, so the gate always
  has a way to be satisfied.
- Every workflow declares explicit least-privilege `permissions`.
- `pull_request_target` is used in exactly one workflow, which checks out
  nothing from the pull request and passes every value through `env:`.

[Unreleased]: https://github.com/TeamNova-SRI-KO-LMS/infrastructure/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/TeamNova-SRI-KO-LMS/infrastructure/releases/tag/v1.0.0
