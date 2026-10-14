# Decisions

## D1. Solver instead of heuristics (2025-11)

We tried a greedy "earliest free slot" scheduler first. It worked until ~200 jobs, then produced pile-ups at midnight. CP-SAT solves 2,000 jobs/41 boxes in ~8 s. Cost: a Python dependency in an otherwise Go service; the planner runs as a separate process.

## D2. Immutable versioned plans (2025-12)

Editing a live plan caused agents to run jobs twice when the edit raced a poll. Now a plan is never edited; a new one is written with `effective_at` in the future (≥ 2 polling intervals), and agents switch atomically.

## D3. No local cache in agents (2026-02)

Proposed: agents cache the plan on disk so a Postgres outage doesn't stall them. Rejected: a stale cache made agents run jobs the planner had moved, during the March incident drill. Stalling is the safer failure. Revisit if Postgres availability drops below 99.9%.

## D4. `/why` endpoint (2026-04)

Half of support questions were "why did my job run at 3am". The solver's assignment trace is now stored with the plan and exposed; it doubled the plan row size, which we accepted.

## D5. Duration estimates from actuals (2026-06)

Job owners' declared durations were off by 2–3x. The planner now uses the p90 of the last 20 runs, falling back to the declared value for new jobs. Side effect: a job that once ran long gets a big slot for a while; there is a manual `reset-estimate` command.

## D6. Heartbeat 10 s, poll 30 s (2026-07)

Trade-off between Postgres write load (41 boxes × heartbeats) and detection time. 10 s heartbeat means a dead box is noticed within 30 s; the plan is only recomputed every 5 min anyway.
