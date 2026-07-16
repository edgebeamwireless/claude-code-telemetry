"""Synthetic telemetry generator.

Emits the SAME metric names and attributes that real Claude Code emits
(https://code.claude.com/docs/en/monitoring-usage), so the Grafana dashboard
can be validated end-to-end without wiring up real clients. Once real clients
push to the collector this script is no longer needed.
"""
import random
import time
from opentelemetry import metrics
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter

exporter = OTLPMetricExporter(endpoint="http://localhost:4317", insecure=True)
reader = PeriodicExportingMetricReader(exporter, export_interval_millis=5000)
provider = MeterProvider(metric_readers=[reader])
metrics.set_meter_provider(provider)

meter = metrics.get_meter("claude-code-test")

# Real Claude Code metric names (dots -> underscores in Prometheus).
session_count = meter.create_counter("claude_code.session.count", description="CLI sessions started")
token_usage = meter.create_counter("claude_code.token.usage", description="Tokens used")
cost_usage = meter.create_counter("claude_code.cost.usage", description="Session cost in USD")
edit_decision = meter.create_counter("claude_code.code_edit_tool.decision", description="Code edit permission decisions")

# Fake addresses (.invalid is reserved by RFC 2606 and can never resolve) so this
# synthetic data never impersonates a real employee.
users = [
    "user1@example.invalid",
    "user2@example.invalid",
    "user3@example.invalid",
    "user4@example.invalid",
]
model = "claude-sonnet-5"

while True:
    user = random.choice(users)
    # synthetic=true so this generated data is filterable / excludable in queries.
    base = {"user.email": user, "model": model, "synthetic": "true"}

    session_count.add(1, {**base, "start_type": "fresh"})

    # Token usage is reported split by type; cost derived from a realistic blended rate.
    input_tokens = random.randint(2000, 8000)
    output_tokens = random.randint(500, 3000)
    token_usage.add(input_tokens, {**base, "type": "input"})
    token_usage.add(output_tokens, {**base, "type": "output"})

    cost = input_tokens * (3 / 1_000_000) + output_tokens * (15 / 1_000_000)
    cost_usage.add(cost, {**base, "query_source": "main"})

    # Code edit decisions (accept/reject) drive the acceptance-rate panel.
    for _ in range(random.randint(1, 10)):
        decision = "accept" if random.random() < 0.8 else "reject"
        edit_decision.add(1, {
            "user.email": user,
            "decision": decision,
            "tool_name": random.choice(["Edit", "Write"]),
            "language": random.choice(["Python", "TypeScript", "YAML"]),
            "synthetic": "true",
        })

    time.sleep(10)
