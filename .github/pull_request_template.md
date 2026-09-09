## What this changes

<!-- One paragraph. What did the infrastructure do before, what does it do now,
     and why. A reviewer should be able to decide from this whether the diff is
     the right diff, before reading the diff. -->

Closes #

## Why

<!-- The failure this prevents, or the requirement it satisfies. -->

## Blast radius

<!-- A change here can affect every repository's pipeline and every
     environment. Which of these does this touch? -->

- [ ] CI only — no deployed environment is affected
- [ ] Staging
- [ ] **Production**
- [ ] The published action — other repositories consume this
- [ ] The published images

## How this was verified

<!-- Not "CI is green". Which stack was brought up, which command was run,
     what was observed. -->

```bash
npm run validate
docker compose -f compose/docker-compose.yml up -d --wait
./scripts/smoke-test.sh http://localhost:5173 http://localhost:5001
```

## Rollback

<!-- How to undo this if it goes wrong in an environment. A deployment or
     schema change with no answer here is not ready. -->

## Checklist

- [ ] No secret, token or connection string in the diff — including defaults,
      examples and comments
- [ ] Every new workflow declares `permissions:` and grants the minimum
- [ ] Every new workflow declares a `concurrency` group
- [ ] Actions pinned to a release tag or a commit SHA — never `@main`
- [ ] No untrusted pull-request input interpolated into a `run:` block
- [ ] Any new container runs as a non-root user
- [ ] Shell steps start `set -euo pipefail`
- [ ] `npm run validate` passes
- [ ] `CHANGELOG.md` updated under `[Unreleased]`
- [ ] Documentation updated if the deployment or secret set changed
- [ ] CI green; at least one peer review with all `[blocker]` comments resolved
