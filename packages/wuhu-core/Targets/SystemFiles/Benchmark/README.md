# Skill benchmark

What the system `AGENTS.md` and skills do for a cheap model: everyday prompts (`cases.json`, intent in `cases.md`), each run a few times on `deepseek/deepseek-flash` in an empty space, scored by deterministic checks plus an LLM judge.

- `cases.json`: prompts, required checks, expected skill reads (negatives included), judge rubrics.
- `fixtures/`: the seed every subject gets its own copy of (`*.table.json` become tables).
- `conditions/<name>/`: a session template (`AGENTS.md`, `.agents/skills/*`) layered over the server's own system files; `baseline` is no template.
- `models.json`: the scratch server's `/models.json`, the subject provider only.
- `model-groups.json`: the scratch server's separate group catalog; bench-deepseek selects its one DeepSeek Flash member. Seeding writes declarations only, never creates a grouped child.

The runner, its checks and the re-run recipe are in the monorepo's `tools/skill-bench/`.
