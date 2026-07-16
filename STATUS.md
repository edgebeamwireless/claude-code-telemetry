# OPS-235 Telemetry Stack — Status & Handoff

_Last updated: 2026-07-16 — handoff for Joseph Lancaster_

## TL;DR
The stack is live on the VM, self-contained, and shows **real** Claude Code
telemetry. Security triage **Phase 1** is complete. Phase 2/3 remain (file as
tickets). The repo is the source of truth; the VM tracks `origin/main`.

## Environment
- **VM:** `ubuntu@18.215.170.79` (EC2 `i-0aec393b021b5ef2c`, us-east-1), key `~/.ssh/ops-telemetry-key.pem`
- **Grafana:** http://18.215.170.79:3000  (admin password in the VM's `.env`)
- **Stack** (`~/claude-code-telemetry`, docker compose): otel-collector, prometheus, loki, grafana
- **SG** `sg-0c10615c3983e2f47`: IP allowlist via `./update-sg.sh` (operator all-ports; `team-ips.txt` on 4317/4318). Operator IP rotates on cellular — re-run before connecting.

## What works
- All four containers healthy; images pinned by digest; survives reboot (systemd unit + `unless-stopped`, verified by an actual reboot).
- OTLP ingest requires a bearer token; unauthenticated push → 401.
- Real telemetry flowing; dashboard renders all 5 panels (Token Use, Sessions, Cost, Code Acceptance, Code Rejection), keyed by `user_email`.
- **Self-contained data:** hourly `cron-telemetry.sh` runs a real session (with an accepted edit) so every panel stays populated with no external client.

## Security triage — Phase 1 (DONE)
1. **Grafana CVE-2026-27876** — running 13.1.0, above the 11.6–12.4 range → not vulnerable.
2. **Images pinned** to version + `@sha256` digest (grafana 13.1.0, prometheus v3.13.1, loki 3.7.3, otel-collector 0.156.0).
3. **Internal ports closed** — 9090/3100/8889 no longer published to the host (docker-network only); only 4317/4318 + 3000 are exposed.
4. **Grafana password fail-safe** — `${GRAFANA_ADMIN_PASSWORD:?}`; strong password set on the VM (`admin/admin` fallback and the `<from-secrets-manager>` placeholder are gone).
5. **Test data cleaned** — `test_telemetry.py` uses `*.invalid` emails + `synthetic=true`.

## Key gotchas for whoever runs this
- **Dashboard time range:** per-session metrics go stale; panels use `last_over_time([$__range])`. Keep the range ≥ a few hours (default `now-6h`) or panels read empty.
- **Scrape latency ~30–40s** (10s client export + 30s Prometheus scrape).
- **Grafana password rotation:** Grafana only reads the env var on first volume init. To change it: edit `.env` **and** run `docker compose exec grafana grafana cli admin reset-admin-password <new>`.
- **Debugging internal ports:** now that 9090/3100/8889 aren't on the host, use `docker compose exec <svc> ...`.
- **Secrets:** `.env` (VM only, gitignored) holds `GRAFANA_ADMIN_PASSWORD` + `OTEL_INGEST_TOKEN`. Not in git.

## Remaining work (Phase 2 / 3 — file as OPS-235 sub-tickets)
- **Phase 2:** TLS/encrypted transport (OPS-405); resource limits + collector `memory_limiter` + container hardening (OPS-406); `update-sg.sh` safety hardening (OPS-408). **IMDSv2 enforced — done** (OPS-407: `http-tokens required`, hop-limit 1; IMDSv1 now 401, containers blocked).
- **Phase 3:** per-client tokens/mTLS; privacy & retention (hash/drop emails+session IDs, Loki retention, EBS encryption, data-owner docs); scope IAM for the SG script; network segmentation (frontend/ingestion/backend docker networks).
- Publish the Confluence runbook. (Repo transfer to the edgebeamwireless org: done.)

## Deploy / onboarding
See **DEPLOY.md** (secrets, deploy, client onboarding, reboot recovery). Repo:
https://github.com/edgebeamwireless/claude-code-telemetry
