# Sundial

Sundial is our internal scheduling service: it decides when recurring jobs run across the fleet so that no two heavy jobs overlap on the same box.

Repo layout:

- `core/` — the planner (constraint solver + calendar math)
- `api/` — HTTP API, gRPC gateway
- `agents/` — the per-box agent that reports load and runs what the planner says
- `ops/` — deployment manifests, dashboards

Owners: Mei (planner), Tomas (API + agents), Rob (ops).

See `architecture.md`, `decisions.md`, `glossary.md`, `onboarding-faq.md`.
