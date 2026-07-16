# Deploying the OPS-235 Telemetry Stack

The stack runs via `docker compose` on the VM (`ubuntu@<VM_PUBLIC_IP>`,
`~/claude-code-telemetry`). Secrets live in a **gitignored `.env`** on the VM,
never in the repo.

## Components
- `docker-compose.yml` — otel-collector, prometheus, loki, grafana
- `otel-collector-config.yaml` — OTLP (bearer-auth) in → Prometheus + Loki
- `provisioning/` — Grafana datasources + the analytics dashboard
- `bootstrap-claude-telemetry.sh` — point a Claude Code client at the collector
- `update-sg.sh` + `team-ips.txt` — manage who can reach the collector

## Secrets (`.env` on the VM)
```bash
cd ~/claude-code-telemetry
cp .env.example .env && chmod 600 .env
# then set:
#   GRAFANA_ADMIN_PASSWORD=<strong value>
#   OTEL_INGEST_TOKEN=$(openssl rand -hex 32)   # shared telemetry-push token
```
`docker-compose.yml` reads `${GRAFANA_ADMIN_PASSWORD}` and requires
`${OTEL_INGEST_TOKEN:?}` (the collector refuses to start without it, so auth is
never silently disabled).

> There is also an optional Bitwarden Secrets Manager path (`deploy.sh` +
> `.bws.env`) if you'd rather pull secrets from `bws` at deploy time instead of
> keeping them in `.env`. It expects the var named `GF_SECURITY_ADMIN_PASSWORD`;
> reconcile that with the `.env` approach before using it.

## Deploy
```bash
cd ~/claude-code-telemetry
git pull
docker compose up -d
```
Grafana applies `GF_SECURITY_ADMIN_PASSWORD` on every start, so editing `.env`
and re-running `docker compose up -d` resets the admin password.

---

## Authentication model
The OTLP receivers (4317/4318) require a **shared bearer token**
(`OTEL_INGEST_TOKEN`). A push without `Authorization: Bearer <token>` is rejected
with 401. Network access is additionally gated by the security group (below), so
a client needs **both** an allowlisted IP **and** the token.

User identity on the dashboard comes from each person's own Claude login
(`user_email` label) — not from the token — so one shared token still yields
per-person breakdowns.

## Onboarding a new user (telemetry-push)
1. **Allowlist their IP.** Add a line to `team-ips.txt`:
   ```
   203.0.113.9   Jane (home)
   ```
   Commit it, then run `./update-sg.sh` (opens 4317/4318 for that IP only — no
   SSH/Grafana). Requires a **static** IP; cellular/dynamic IPs won't stay valid.
2. **Give them the token** (`OTEL_INGEST_TOKEN`) over a secure channel.
3. **They configure their client** from a clone of this repo:
   ```bash
   ./bootstrap-claude-telemetry.sh <OTEL_INGEST_TOKEN> http://<VM_PUBLIC_IP>:4317
   ```
   New Claude Code sessions on their machine then export authenticated telemetry.

**Removing a user:** delete their line from `team-ips.txt`, run `./update-sg.sh`.
To fully cut off everyone at once, rotate `OTEL_INGEST_TOKEN` in `.env` and
`docker compose up -d`.

## Enabling telemetry on the VM itself
```bash
./bootstrap-claude-telemetry.sh "$(grep ^OTEL_INGEST_TOKEN= .env | cut -d= -f2)"
```
(defaults to `http://localhost:4317`). Verify data is arriving:
```bash
curl -s http://localhost:9090/api/v1/label/__name__/values | jq -r '.data[]' | grep claude
```
Metrics take up to ~40s to appear (10s client export + 30s Prometheus scrape).
Set the Grafana time range wide enough (e.g. 24h) — per-session series go stale
(see STATUS.md).

## Security-group access
`update-sg.sh` reconciles `sg-0c10615c3983e2f47` to exactly: the operator's
current IP (all ports) + every `team-ips.txt` entry (4317/4318 only). Re-run it
whenever the operator's cellular IP rotates — it won't evict teammates.
```bash
./update-sg.sh
```
