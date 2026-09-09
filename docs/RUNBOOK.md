# Runbook

First response when something is broken. Written to be read by whoever is
nearest, not by whoever wrote it — including at an hour when nobody is at their
best, and including during the week of the final demonstration.

**The first rule: restore service, then investigate.** A rollback takes ninety
seconds and can always be reversed. Debugging a broken production while users
are on it is the slower path to both outcomes.

---

## Triage

| Symptom                        | Go to                                                           |
| ------------------------------ | --------------------------------------------------------------- |
| Deployment failed in CI        | [A deployment failed](#a-deployment-failed)                     |
| Site returns 502 / 504         | [The site is down](#the-site-is-down)                           |
| Site loads, everything 401s    | [Everyone is logged out](#everyone-is-logged-out)               |
| Deep links 404, home page fine | [Deep links 404](#deep-links-404)                               |
| API errors mentioning Mongo    | [The database will not connect](#the-database-will-not-connect) |
| Everything is slow             | [Everything is slow](#everything-is-slow)                       |
| Containers restarting          | [A container is restarting](#a-container-is-restarting)         |
| Disk full                      | [The disk is full](#the-disk-is-full)                           |
| A secret leaked                | [SECRETS.md](SECRETS.md#if-a-secret-is-committed)               |

### The first three commands

```bash
ssh deploy@<host> && cd /opt/sri-ko-lms

docker compose ps                       # what is running, and is it healthy
docker compose logs --tail=100 api      # what it said before it stopped
cat .deployed-tag                       # what is supposed to be running
```

---

## A deployment failed

The action rolls back automatically when a health check or smoke test fails, so
first establish whether it already did.

```bash
cat .deployed-tag                       # if this is the *previous* tag, it rolled back
tail -5 .deployment-history
```

Then read the failure. The workflow uploads `failed-deployment-logs-<env>` as an
artefact — the logs from the failed containers, captured _before_ the rollback
replaced them.

| In the logs                                      | Cause                                                     | Fix                                                               |
| ------------------------------------------------ | --------------------------------------------------------- | ----------------------------------------------------------------- |
| `JWT_SECRET is not set` / stack refuses to start | A missing key in the host `.env`                          | Compare against `.env.example`, redeploy                          |
| `MongoServerError: Authentication failed`        | Wrong `MONGO_APP_PASSWORD`, or the user was never created | [Database](#the-database-will-not-connect)                        |
| `manifest unknown` on pull                       | The tag is not in the registry                            | Check `docker-publish.yml` ran for that commit                    |
| `no space left on device`                        | Disk                                                      | [Disk](#the-disk-is-full)                                         |
| Healthy but the smoke test failed                | The app started but is not serving correctly              | Run `./scripts/smoke-test.sh` by hand and read which check failed |
| `permission denied` on a script                  | Scripts lost their executable bit                         | `chmod +x scripts/*.sh` — `validate.js` checks this in CI         |

If it did not roll back and the environment is broken:

```bash
./scripts/rollback.sh production
```

## The site is down

```bash
docker compose ps
```

**Containers are not running:**

```bash
docker compose logs --tail=200
docker compose up -d --wait --wait-timeout 180
```

**Containers are running but the site 502s:** the reverse proxy cannot reach
`web`.

```bash
curl -f http://localhost:8080/healthz    # from the host
docker compose port web 8080             # is the port actually published
sudo systemctl status caddy              # or nginx
```

**`web` is up but the API is not:** the proxy inside nginx has no upstream.

```bash
docker compose exec web wget -qO- http://api:5001/health
```

If that fails, `api` is down or not on the same network — restart the stack.

**Nothing obvious in two minutes:** roll back. Investigating a live outage is
what the previous tag buys you the time to do.

```bash
./scripts/rollback.sh production
```

## Everyone is logged out

The site loads and every authenticated request returns 401.

Almost always: `JWT_SECRET` changed. Every existing token was signed with the
old value and no longer verifies.

```bash
docker compose exec api printenv JWT_SECRET | head -c 8   # first bytes only
```

- **If it changed deliberately** (a rotation), this is the intended effect.
  Users log in again; say so rather than debugging it.
- **If it changed accidentally** — a redeploy with a different `.env`, or the
  variable missing so the application fell back to its built-in constant
  (`DEFECT-03`) — restore the correct value and redeploy. Then read
  [SECRETS.md](SECRETS.md): if the fallback was ever live, every token issued
  in that window was signed with a value published in the source, and the
  secret must be rotated for real.

## Deep links 404

`/` works, `/courses` returns 404 on refresh.

The SPA fallback is broken: nginx is not serving `index.html` for paths that
are not files.

```bash
docker compose exec web cat /etc/nginx/conf.d/default.conf | grep -A3 'location /'
```

It must contain `try_files $uri $uri/ /index.html;`. If the file is the stock
nginx default, the config was not copied into the image — rebuild the frontend
image and redeploy.

`smoke-test.sh` checks for this specifically, so a deployment that introduces
it should have been caught. If it was not, the smoke test was skipped.

## The database will not connect

```bash
docker compose logs api | grep -i mongo | tail -20
docker compose exec mongo mongosh --quiet --eval 'db.adminCommand("ping")'
```

| Error                           | Cause                                                      | Fix                                                                                             |
| ------------------------------- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `Authentication failed`         | Wrong credentials, or `authSource` missing from the URI    | The URI must end `?authSource=<database>` — the app user lives in the app database, not `admin` |
| `ECONNREFUSED mongo:27017`      | The container is not up, or not on the network             | `docker compose up -d mongo`                                                                    |
| `getaddrinfo ENOTFOUND`         | Service name mismatch between the URI and the compose file | They must agree                                                                                 |
| Timeout on a managed cluster    | The host's IP is not in the access list                    | Add it in the provider console                                                                  |
| `IndexOptionsConflict` on start | A schema index was changed without dropping the old one    | Drop the named index and let the app recreate it                                                |

If the data itself is wrong — an unfinished migration, a bad deploy — restore
the pre-deployment snapshot into a **scratch** database first and look at it
before touching the live one:

```bash
mongorestore --uri="$MONGODB_URI" --gzip \
  --archive=/opt/sri-ko-lms/backups/sriko-pre-v1.2.3-<timestamp>.gz \
  --nsFrom='sriko_lms.*' --nsTo='sriko_scratch.*'
```

## Everything is slow

```bash
docker stats --no-stream
docker compose logs api --tail=200 | grep -iE 'slow|timeout'
```

| Observation                    | Likely cause                     | Response                                                                   |
| ------------------------------ | -------------------------------- | -------------------------------------------------------------------------- |
| API at its CPU limit           | Under-provisioned, or a hot loop | Raise `deploy.resources.limits`, or find the endpoint                      |
| API memory climbing steadily   | Leak                             | Restart to restore service, then capture a heap snapshot before it is lost |
| Mongo at high CPU, API idle    | A query with no index            | Check `db.currentOp()` and the slow query log                              |
| Both idle, requests still slow | The network or the proxy         | Check the reverse proxy, then DNS                                          |

There is no cache layer, so every request reaches the database. The catalogue is
the first thing to cache when this becomes chronic — it is read constantly and
written rarely.

## A container is restarting

```bash
docker compose ps                                   # restart count
docker compose logs --tail=100 <service>
docker inspect <container> --format '{{.State.ExitCode}} {{.State.OOMKilled}}'
```

- **`OOMKilled: true`** — it hit the memory limit. Raise it, or find what is
  allocating. Restarting without doing either buys minutes.
- **Exit 1 immediately** — it fails on startup. The first lines of the log say
  why; usually a missing environment variable.
- **Healthy, then unhealthy, then restarted** — the healthcheck is failing.
  Run it by hand: `docker compose exec api node -e "..."` (the command is in
  `docker/backend.Dockerfile`).

## The disk is full

```bash
df -h
docker system df
```

Usually Docker. In order of what to remove first:

```bash
docker image prune -af --filter 'until=168h'   # images older than a week
docker builder prune -af                        # build cache
docker container prune -f                       # stopped containers
```

Then check the logs and the backups:

```bash
du -sh /var/lib/docker/containers/*/*.log | sort -h | tail
du -sh /opt/sri-ko-lms/backups
```

If a container log has grown large, the `max-size` limit is missing from that
service. Add it — an unrotated json-file log fills a disk silently, and the
first symptom is the database failing to write.

**Do not run `docker system prune -a --volumes`.** `--volumes` deletes the
database volume. On staging that is the demo data; on a host where production's
uploads live on a volume, it is the uploads.

---

## Escalation

| Situation                                     | Do                                                                                                             |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Production down > 15 min                      | Roll back, notify the team lead, then investigate                                                              |
| Data loss suspected                           | Stop writing immediately. Do not redeploy. Restore into a scratch database and compare                         |
| A secret is exposed                           | Rotate first, then clean history, then tell the supervisor — [SECRETS.md](SECRETS.md#if-a-secret-is-committed) |
| Staging down within 48 h of the demonstration | Treat as production. §9.1: an unresolved live failure is a failed demonstration                                |

## After any incident

1. **Write it down** while it is fresh: what broke, what was seen, what was
   done, what actually fixed it. Memory is worse than you think by Thursday.
2. **Open an issue** with the root cause, not the symptom.
3. **Add the check that would have caught it** — a smoke-test assertion, a
   healthcheck, a CI gate. This is the step that gets skipped, and it is the
   only one that stops the incident recurring.
4. **Bring it to the retrospective.** The
   [retrospective template](https://github.com/TeamNova-SRI-KO-LMS/documentation/blob/main/documents/retrospectives/retrospective-template.md)
   asks for the cause, not the symptom, for exactly this reason.
