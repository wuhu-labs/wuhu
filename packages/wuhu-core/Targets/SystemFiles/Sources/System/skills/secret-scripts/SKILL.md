---
name: secret-scripts
description: Use wuhu:secret placeholders in fetch, list secret names, and set secrets with admin authorization.
script_exports: {"wuhu:secret":["list","remove","secret","set"]}
---

# Secret scripts

Import `{ secret, set, list, remove }` from `wuhu:secret`.

- `secret(name)` returns a placeholder, never the secret value. Fetch substitutes it in the URL, headers and body; sent values are masked as `***` in responses, console, result and update.
- `secret(name, { group })` explicitly names a readable group's secret, never a fallback.
- `list()` lists your group's secret names; `list({ group })` lists those of a readable group.
- `set(name, value)` requires your group's admin (a top-level agent; never a task or child agent).
- `remove(name)` is always refused: removal needs a human admin.

For machine exec secret injection, read [machine-scripts](wuhu://system/skills/machine-scripts/SKILL.md). It uses secret names, not placeholders.
