---
name: machine-scripts
description: Use wuhu:machine — machine files, commands, script-local streaming processes and durable exec ownership.
script_exports: {"wuhu:machine":["execStatus","execs","killExec","machine","machines"]}
---

# Machine scripts

```js
import { machines, machine, execs, execStatus, killExec } from "wuhu:machine"
const boxes = await machines()
const m = machine(boxes[0].id)
result(await m.readText("/var/log/app.log"))
```

## Files and commands

`machines()` lists usable machines. `machine(nameOrID)` returns a handle; all paths below are absolute machine paths, not space paths.

- `stat(path)` returns metadata with `mtime` as a Date, or null if absent. `list(path)` returns entries with the same date conversion.
- `read(path)` returns a Uint8Array; `readText(path)` returns UTF-8 text.
- `write(path, data, { ifMatch? })` accepts a string, ArrayBuffer or typed array. Existing-file overwrites require a prior read at the current mtime; `ifMatch` supplies an explicit guard.
- `remove(path)`, `mkdir(path)` and `move(from, to)` mutate the raw filesystem, without a space revision journal.
- `exec(command, options?)` collects output. `spawn(command, options?)` returns a script-local Process for streaming. Options are `{ cwd?, env?, secrets?, timeout?, maxOutput?, stdin? }`.
- `secrets: { VAR: "SECRET_NAME" }` uses the machine's group, not yours, and masks values in output. Secret placeholders are refused in commands, env and stdin; only fetch fills them in.

## Processes

A Process has an `id`, `lines()` yielding `{ stream: "out" | "err", text }` (line ending and trailing carriage return removed), and raw async iteration yielding `{ stream, data: Uint8Array }`. There is one reader; another iteration throws. Leaving early drops the rest unread. Output is flow-controlled with a 1 MiB window, not dropped when a reader is slow.

`write(data)` queues stdin writes; `end()` closes stdin after queued writes. `wait()` resolves to `{ code, signal }`: code is null for a signal exit. A command that cannot start exits 127 with a `wuhu:` stderr line. `kill()` stops the process. At most eight spawned processes may be live per script.

Processes cannot outlive their script: cancellation aborts pending reads with AbortError and kills processes (TERM, then KILL after five seconds). A server restart kills scripts; their processes are killed about a minute after recovery and the session gets a notice. For monitoring patterns, batching and detached long jobs, read [monitor](wuhu://system/skills/monitor/SKILL.md).

## Durable execs

`execs()` lists only live execs owned by the calling session, including execs started by earlier scripts or its exec tool. `execStatus(id)` can also return terminal records; `killExec(id)` kills an owned exec. Unknown ids and another caller's ids both fail with `notFound`.
