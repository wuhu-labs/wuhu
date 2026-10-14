# Architecture

## Components

1. **Planner** (`core/`): every 5 minutes it reads job definitions and box load from Postgres, builds a 24h horizon plan with the solver (OR-Tools CP-SAT), and writes the plan to the `plan` table. Plans are immutable and versioned; a new plan supersedes the old one at its `effective_at` time.
2. **API** (`api/`): CRUD for job definitions, read access to plans, and a `/why` endpoint that explains why a job was placed where it was (reads the solver's assignment trace).
3. **Agent** (`agents/`): runs on every box. Polls the plan every 30 s, runs jobs at their slot, reports actual start/end and CPU/mem to the `runs` table. Heartbeats every 10 s.
4. **Ops** (`ops/`): Helm charts, Grafana dashboards (planner latency, slot adherence, agent liveness), PagerDuty rules.

## Data flow

job definitions + box load → planner → plan (versioned) → agents (poll) → runs → planner (feedback: actual durations feed the next horizon's estimates)

## Failure modes

- Planner down: agents keep executing the last plan until it ends (24h), then idle. Alert fires after 15 min with no new plan.
- Agent down: its box's jobs are not re-placed automatically; the next plan (≤5 min) sees the box as absent and moves them.
- Postgres down: everything stalls. There is no local cache by design (see decisions).

## Environments

dev (docker-compose), staging (3 boxes), prod (41 boxes as of Oct 2026).
