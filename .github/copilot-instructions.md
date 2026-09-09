# Copilot review instructions — infrastructure

GitHub Copilot reads this file before reviewing a pull request in this
repository. It is guidance for the reviewer, not documentation for people:
short, specific, and about the mistakes that are actually made here.

## What this repository is

Infrastructure as code for the SRI-KO Learning Management System, built for
SENG 34213 at the University of Kelaniya. It holds Dockerfiles, Compose stacks,
GitHub Actions workflows, deployment scripts, and a composite action published
to the GitHub Marketplace. It contains no application code — the API and
frontend live in `SRI-KO_LMS_MERN`.

Because a change here changes how _every_ repository builds, deploys or
releases, the blast radius of a mistake is larger than the diff suggests.

## Review these first

**Secrets.** Flag any literal credential, token, connection string, private key
or password — including in a comment, a default value, an example, or a test
fixture. `${{ secrets.NAME }}` is correct; `password: hunter2` is not, in any
file, for any reason. The course standard (§7) is unconditional: no secret is
committed even to a private repository.

**Workflow permissions.** Every workflow must declare `permissions:` explicitly
and grant the minimum. Flag a workflow with no `permissions` block (it inherits
a broad default), and flag `contents: write` or `packages: write` on a job that
only reads.

**Untrusted input in `pull_request_target`.** A workflow with that trigger runs
with write access and the base repository's secrets. Flag any use that checks
out the pull request head, or that interpolates a PR title, branch name or body
directly into a `run:` block — that is a script-injection path. Use an
environment variable and quote it.

**Unpinned or moving action references.** `uses: some/action@main` is remote
code executing with this repository's token. Flag anything that is not a
release tag, and prefer a full commit SHA for third-party actions.

**Images running as root.** Every Dockerfile here ends with a `USER` that is
not root. Flag a new stage or image that does not.

**Deployment steps with no rollback.** A deploy job that can leave the
environment half-updated needs a documented way back. Flag one that has none.

## Conventions to enforce

- Workflow files are kebab-case: `deploy-production.yml`.
- Job ids are kebab-case; job `name:` is human-readable prose.
- Every workflow has a `concurrency` group, so two pushes cannot deploy at once.
- Shell steps start `set -euo pipefail`. An unchecked failure mid-deploy is
  worse than a failed deploy.
- Compose services declare a healthcheck and a resource limit.
- Commit messages follow Conventional Commits (`ci:`, `build:`, `chore:`,
  `docs:`, `fix:`, `feat:`) with the issue in the footer (`Closes #NN`).

## What not to comment on

- YAML key ordering, or quoting style where both parse identically.
- Long `run:` blocks that are long because a deployment has many steps.
- Comment density. Explanatory comments in this repository are deliberate:
  a workflow is read by whoever is debugging a failed deploy at the worst
  possible moment, and the reasoning has to be next to the step.

## Severity

Use the `[blocker]` / `[suggestion]` / `[question]` / `[nit]` prefixes the team
uses in human review (see the documentation repository,
`documents/standards/code-review-standards.md`). A secret, an over-broad
permission, a script-injection path, or a root container is a `[blocker]`.
Everything else is at most a `[suggestion]`.
