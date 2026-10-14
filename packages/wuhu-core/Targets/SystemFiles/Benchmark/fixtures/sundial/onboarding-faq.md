# FAQ people ask in week one

**How do I run it locally?** `make dev` brings up Postgres, the planner, the API and two fake agents in docker-compose. The planner uses a 1-minute horizon in dev so you see plans quickly.

**Where do I add a job?** Through the API (`POST /jobs`) or the `sundial jobs add` CLI. Never by inserting into Postgres directly; the planner validates schedule expressions on the way in.

**My job didn't run when I expected.** Check `GET /why/<job>` first. 90% of the time: the box was busy with a heavy job, or the duration estimate grew because of one slow run (see D5; `reset-estimate` fixes it).

**Who do I ask?** Planner → Mei. API/agents → Tomas. Dashboards, deploys, alerts → Rob. Channel `#sundial`.

**On-call?** Tomas and Rob rotate weekly. Mei is escalation for solver bugs.

**Staging access?** Ask Rob for the kubeconfig. Staging has 3 boxes; it's fine to break it.
