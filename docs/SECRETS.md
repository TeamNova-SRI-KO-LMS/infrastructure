# Secrets

> **§7:** _NEVER commit secrets (API keys, passwords, tokens, connection
> strings) to the repository — even in private repositories._
>
> Unconditional, and worth understanding why rather than just obeying. A secret
> that reaches a commit is in every clone, every fork, every CI cache that
> already pulled it, and every backup of all of those. Rewriting history does
> not un-share it. The only remedy is to rotate the credential — so the
> question after a leak is never "can we remove it?" but "how fast can we
> replace it?".

## Where each kind of secret lives

| Where                        | What                                                       | Who can read it                      |
| ---------------------------- | ---------------------------------------------------------- | ------------------------------------ |
| GitHub Actions **secrets**   | Everything used by CI and deployment                       | Workflow runs; masked in logs        |
| GitHub Actions **variables** | Non-secret configuration — URLs, paths                     | Workflow runs; visible in logs       |
| GitHub **Environments**      | Per-environment secrets, plus the production approval gate | Only jobs targeting that environment |
| Host `.env`                  | The values the running stack needs                         | The `deploy` user, mode 600          |
| `.env.example`               | The _names_ of all of the above, with placeholders         | Everyone. Committed on purpose       |

`.env.example` is the map. Anyone can see which keys exist without seeing a
single value, which is what makes it possible to onboard someone in an hour
rather than by asking around for a week.

---

## Repository secrets

Set at **Settings → Secrets and variables → Actions → Secrets**.

| Secret               | Used by                                  | What it is                                                                                                        |
| -------------------- | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `DOCKERHUB_USERNAME` | `docker-publish`, deploys                | Docker Hub account                                                                                                |
| `DOCKERHUB_TOKEN`    | `docker-publish`                         | Docker Hub **access token**, not the password                                                                     |
| `APP_REPO_TOKEN`     | `ci`, `docker-publish`, `deploy-staging` | Fine-grained PAT with read access to the application and testing repositories. Only needed while they are private |

`GITHUB_TOKEN` is provided automatically and is what GHCR, releases, issues and
pull-request comments authenticate with. Nothing needs to be created for it.

> Use a Docker Hub **access token**, never the account password. A token is
> scoped to read/write on repositories, can be revoked on its own, and appears
> in the account's token list so a forgotten one is visible.

## Environment secrets

Set at **Settings → Environments → `staging` / `production` → Secrets**.
Scoping them to an environment means a workflow that does not target
`production` cannot read the production key, however it is written.

| Secret                   | Environment       | What it is                                  |
| ------------------------ | ----------------- | ------------------------------------------- |
| `STAGING_HOST`           | staging           | Hostname or IP of the staging Docker host   |
| `STAGING_USER`           | staging           | SSH user, conventionally `deploy`           |
| `STAGING_SSH_KEY`        | staging           | Private key for that user                   |
| `STAGING_ENV_FILE`       | staging           | Base64 of the complete `.env` for staging   |
| `PRODUCTION_HOST`        | production        | Hostname or IP of the production host       |
| `PRODUCTION_USER`        | production        | SSH user                                    |
| `PRODUCTION_SSH_KEY`     | production        | Private key                                 |
| `PRODUCTION_ENV_FILE`    | production        | Base64 of the production `.env`             |
| `PRODUCTION_MONGODB_URI` | production-backup | Connection string used by `backup-mongo.sh` |

Encode an env file with:

```bash
base64 -i .env | tr -d '\n' | pbcopy      # macOS
base64 -w0 .env                            # Linux
```

The deploy action writes it to the host through a pipe with `umask 077`, so the
file never exists in a world-readable state — not even for the moment between
being written and being chmod-ed.

## Variables

Not secret. Kept as variables so they appear in logs, which makes a deployment
that went to the wrong URL obvious rather than mysterious.

| Variable                | Example                                  |
| ----------------------- | ---------------------------------------- |
| `STAGING_URL`           | `https://staging.sri-ko-lms.example`     |
| `STAGING_API_URL`       | `https://api.staging.sri-ko-lms.example` |
| `STAGING_PATH`          | `/opt/sri-ko-lms-staging`                |
| `PRODUCTION_URL`        | `https://sri-ko-lms.example`             |
| `PRODUCTION_API_URL`    | `https://api.sri-ko-lms.example`         |
| `PRODUCTION_PATH`       | `/opt/sri-ko-lms`                        |
| `VITE_API_URL`          | `/api`                                   |
| `VITE_GOOGLE_CLIENT_ID` | The public OAuth client id               |

`VITE_*` values are inlined into the JavaScript bundle at build time and shipped
to every browser. Only ever put public values there. A "secret" passed as a
Vite build argument is a secret published in the page source.

---

## Generating the application secrets

```bash
openssl rand -base64 48     # JWT_SECRET
openssl rand -base64 48     # SESSION_SECRET
openssl rand -base64 32     # MONGO_APP_PASSWORD
```

Different values per environment. Sharing `JWT_SECRET` between staging and
production means a token minted on staging authenticates against production —
and staging is the environment with the demo accounts and the loosest access.

> **`JWT_SECRET` must be set.** The application falls back to a constant
> published in its own source when the variable is missing (`DEFECT-03`), and
> nothing warns that it has happened — every token becomes forgeable by anyone
> who has read the repository. Every compose file here declares it with
> `${JWT_SECRET:?}`, so the stack refuses to start rather than starting
> insecurely.

## Rotating a secret

Same procedure whether it is scheduled or a response to a leak. Under exposure,
do it in this order and do not stop halfway — a half-rotated credential is
still a valid credential.

1. **Generate the replacement.** Do not reuse a previous value.
2. **Update the store** — the GitHub secret, and the host `.env` if the host
   holds its own copy.
3. **Redeploy.** The stack reads its environment at start; a running container
   keeps the old value until it is replaced.
4. **Revoke the old credential** at the source: delete the Docker Hub token,
   remove the SSH key from `authorized_keys`, drop the database user.
5. **Verify.** Confirm the old value no longer works. A rotation that was not
   verified is a rotation that may not have happened.

Rotating `JWT_SECRET` invalidates every issued token, so every user is logged
out. That is the intended effect after an exposure: the tokens minted with the
old secret are exactly what is being revoked.

## If a secret is committed

1. **Rotate first.** Before rewriting anything, before telling anyone. The
   secret is already public to everyone with a clone; the only thing that helps
   is making it useless.
2. **Then clean the history** — `git filter-repo`, or BFG. Everyone re-clones.
3. **Tell the supervisor.** §10.3 assesses code quality and security; a handled
   incident with a written response is a better outcome than a hidden one.
4. **Write down what let it happen** and fix that. A `.env` that was not
   ignored, a debug line that printed a token, a screenshot in an issue.

## What already enforces this

| Control                            | Where                       | Catches                                                     |
| ---------------------------------- | --------------------------- | ----------------------------------------------------------- |
| `gitleaks` on full history         | `ci.yml`                    | A committed secret, including one removed in a later commit |
| `npm run validate`                 | `ci.yml`, locally           | AWS keys, GitHub tokens, private keys, MongoDB passwords    |
| `.gitignore`                       | repository root             | `.env`, `*.pem`, `*.key`, `id_rsa*`                         |
| `.dockerignore`                    | repository root             | The same files being copied into an image                   |
| Dockerfile `RUN rm -f config*.env` | `docker/backend.Dockerfile` | Config files baked into the published image                 |
| CodeQL                             | `codeql.yml`                | Hard-coded credentials in the action and scripts            |
| Copilot review                     | `copilot-review.yml`        | A literal credential in a diff, flagged as `[blocker]`      |

Six controls for one rule, which is proportionate: it is the rule where a single
miss is unrecoverable.
