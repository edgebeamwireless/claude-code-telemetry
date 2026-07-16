# Claude Code Telemetry Stack — OPS-235

## Project Overview
Self-hosted telemetry stack tracking Claude Code usage across EdgeBeam Wireless:
token usage, session counts, cost, and code-edit accept/reject decisions, shown
on an auto-provisioned Grafana dashboard. Runs entirely on one EC2 VM.

## Architecture
```
Claude Code clients ──OTLP (bearer-token auth)──▶ OTel Collector (4317 gRPC / 4318 HTTP)
                                                     ├── push logs → Loki (:3100)
                                                     └── expose metrics :8889 → scraped by Prometheus (:9090, 30s)
                                                  Grafana (:3000) queries Prometheus + Loki
```
Only 4317/4318 (ingest) and 3000 (Grafana) are published to the host; 8889/9090/3100
are docker-network-internal only. All inter-service traffic uses service names.

## Stack (docker compose, pinned by digest)
- otel-collector `otel/opentelemetry-collector-contrib:0.156.0`
- prometheus `prom/prometheus:v3.13.1` (retention 30d/10GB, admin API on)
- loki `grafana/loki:3.7.3`
- grafana `grafana/grafana:13.1.0`

## Real Claude Code metrics (Prometheus names)
| Metric | Notes |
|--------|-------|
| `claude_code_token_usage_tokens_total` | label `type` = input/output/cacheRead/cacheCreation |
| `claude_code_session_count_total` | one series per `session_id` |
| `claude_code_cost_usage_USD_total` | USD |
| `claude_code_code_edit_tool_decision_total` | label `decision` = accept/reject |
| `claude_code_active_time_seconds_total` | |

All carry a `user_email` label (identity comes from each person's Claude login,
via the collector's `resource_to_telemetry_conversion`). Per-session series go
**stale** after a session ends — dashboard panels use
`last_over_time(<metric>[$__range])` so totals survive across ended sessions.

## Dashboard panels (`provisioning/dashboards/claude-code-analytics.json`)
1. **Token Use** (stat) — `sum by (user_email) (last_over_time(claude_code_token_usage_tokens_total[$__range]))`
2. **Total Claude Sessions** (stat) — `...claude_code_session_count_total...`
3. **Claude Cost** (gauge) — `...claude_code_cost_usage_USD_total...`
4. **Code Acceptance** (gauge) — `...code_edit_tool_decision_total{decision="accept"}...`
5. **Code Rejection** (gauge) — `...code_edit_tool_decision_total{decision="reject"}...`

Set the dashboard time range (default `now-6h`) wide enough to cover recent
activity, or panels read empty.

## Security / auth
- OTLP receivers require `Authorization: Bearer <OTEL_INGEST_TOKEN>` (401 otherwise).
- Secrets (`GRAFANA_ADMIN_PASSWORD`, `OTEL_INGEST_TOKEN`) live in a gitignored
  `.env` on the VM; compose requires them (`:?`) so it never boots insecurely.
- Grafana admin password: set once via env on volume init, then rotate with
  `docker compose exec grafana grafana cli admin reset-admin-password <new>`.
- Security group `sg-0c10615c3983e2f47` is an IP allowlist managed by
  `update-sg.sh` (operator IP on all ports; `team-ips.txt` entries on 4317/4318).

## Self-contained operation
- `cron-telemetry.sh` (hourly cron on the VM) runs a small real Claude session
  that also makes a changing edit under `acceptEdits`, keeping all panels fresh
  with no external client.
- `telemetry-stack.service` (systemd) + `restart: unless-stopped` + enabled
  docker/cron ⇒ the stack and data generation self-recover on reboot/crash.
- Named volumes (`prometheus_data`, `loki_data`, `grafana_data`) persist data.

## Deployment
- **VM:** EC2 `i-0aec393b021b5ef2c`, Ubuntu 24.04, us-east-1, `18.215.170.79`
- **Grafana:** http://18.215.170.79:3000
- **Repo:** https://github.com/bszczurko-sudo/claude-code-telemetry
- Full runbook: **DEPLOY.md** · Handoff status: **STATUS.md**

## Onboarding a client
`./bootstrap-claude-telemetry.sh <OTEL_INGEST_TOKEN> [http://<VM_IP>:4317]` merges
the telemetry `env` block (incl. the bearer header) into `~/.claude/settings.json`.
Remote clients also need their IP in `team-ips.txt` + `./update-sg.sh`.

## Files
```
docker-compose.yml              four-service stack, pinned images, secrets via .env
otel-collector-config.yaml      OTLP (bearer auth) → Prometheus + Loki
prometheus.yml                  30s scrape of collector:8889
provisioning/                   Grafana datasources + dashboard JSON
update-sg.sh + team-ips.txt     SG allowlist reconcile
bootstrap-claude-telemetry.sh   point a client at the collector
cron-telemetry.sh               hourly real-data heartbeat
telemetry-stack.service         systemd boot unit
test_telemetry.py               synthetic generator (smoke-test only; *.invalid users)
```

## Jira
- Ticket: OPS-235 (parent: OPS-8) · Assignee: Brett Szczurko
- Stakeholders: Joseph Lancaster (analytics), Don Dewar (creator), Huseyin Esin (AWS/VM)

## Remaining / follow-ups
- Security triage Phase 2/3 (TLS, resource limits, container hardening,
  IMDSv2, per-client tokens, privacy/retention, IAM scoping, netseg).
- Transfer repo to the edgebeamwireless GitHub org.
- Publish the Confluence runbook.
