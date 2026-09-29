---
name: monitor
description: Watch something on a machine from run_script — a log, a build, a long command — and get one message per event instead of polling. Covers result() then update(), the tail -F | grep pattern, batching, run-until-exit with a verdict, and stopping cleanly.
---

# Monitoring a machine from run_script

A monitor is a `run_script` module that starts a process on a machine with `wuhu:machine`'s `spawn`, answers the tool call at once, and then sends you one `update()` per event. Each update reaches you later as a message, so you stop polling: the space wakes you when something happens.

The shape is always the same:

1. `result(...)` right away, before the long wait. It answers the `run_script` call; until you call it, the call blocks (up to `timeout_seconds`).
2. One `update(...)` per event. Every update is a message that wakes you and costs a turn, so send only what you would act on. Batch chatty sources.
3. The script ends when nothing is pending: the process exits and you stop reading. Its processes die with it.

## Watch a log: one update per matching line

```js
import { machine } from "wuhu:machine";

const m = machine("app-server");
const p = await m.spawn("tail -n0 -F /var/log/app.log | grep --line-buffered -E 'ERROR|FATAL'");
result(`watching /var/log/app.log on app-server (process ${p.id})`);

for await (const { stream, text } of p.lines()) {
  if (stream === "out") update(text);
}
```

- `tail -n0 -F` starts at the end and follows the file across rotation.
- `grep --line-buffered` matters: without it grep holds its output in a 4 KiB buffer when writing to a pipe, and lines arrive late and in clumps.
- `p.lines()` yields `{ stream: "out" | "err", text }`, one per line, the line ending and a trailing `\r` removed. Raw bytes: `for await (const { stream, data } of p)`. A process has one reader; a second `lines()` or iteration throws.
- Pass `max_lifetime_seconds` to `run_script` for anything that should outlive the default hour. When the lifetime runs out, the script and its processes are killed and you get a notice.

## Batch a chatty source: flush every 5 s

```js
import { machine } from "wuhu:machine";

const m = machine("app-server");
const p = await m.spawn("tail -n0 -F /var/log/access.log | grep --line-buffered ' 5[0-9][0-9] '");
result(`watching 5xx responses on app-server (process ${p.id})`);

let batch = [];
const flush = () => {
  if (batch.length) update(`${batch.length} lines:\n` + batch.splice(0).join("\n"));
};
const reading = new AbortController();
const flusher = (async () => {
  while (true) {
    await sleep(5000, { signal: reading.signal });
    flush();
  }
})().catch(() => {});

for await (const { text } of p.lines()) batch.push(text);
reading.abort();
await flusher;
flush();
```

`sleep(ms, { signal })` rejects when that signal aborts, so the flusher stops the moment the reader is done instead of keeping the script alive another 5 s.

## Run until exit, then give a verdict

```js
import { machine } from "wuhu:machine";

const m = machine("build-box");
const p = await m.spawn("make test", { cwd: "/home/dev/repo" });
result(`running the tests on build-box (process ${p.id})`);

const failed = [];
for await (const { text } of p.lines()) {
  if (text.includes("FAILED")) {
    failed.push(text);
    update(text);
  }
}
const { code, signal: killedBy } = await p.wait();
update(
  code === 0
    ? "PASS"
    : `FAIL (${code === null ? `signal ${killedBy}` : `exit ${code}`}), ${failed.length} failing lines`,
);
```

`wait()` resolves with `{ code, signal }`: `code` is the exit status, or `null` when a signal ended the process. A command that cannot start at all (bad `cwd`, a secret the machine's group lacks) exits 127 with a `wuhu:` line on stderr.

## Stopping

- `stop_script` with the script id aborts `signal`, the global `AbortSignal` every script has. Pending reads reject with an `AbortError`, the script ends, and every process it spawned is killed (TERM, then KILL after 5 s). Nothing extra to write: the processes never outlive the script.
- To stop on your own terms, `p.kill()` the process; the read loop then ends when its output does. Use `signal` for your own waits: `signal.addEventListener("abort", ...)`, or pass it to `fetch` and `sleep`.
- A server restart kills running scripts too. Their processes are killed about a minute after the server comes back, and you get "script X was killed by a server restart". Re-run the monitor if you still need it.

## Limits

- At most 8 spawned processes per script at once.
- Output is flow-controlled, never dropped: each process has a 1 MiB window, and a script that reads slowly stalls its process rather than losing lines. Leaving a `for await` loop early (`break`, `return`, a throw) is the one exception: the rest of that process's output is dropped unread, since a process has only one reader.
- `secrets: { VAR: "SECRET_NAME" }` passes a secret of the machine's group (not yours) as an environment variable, masked as `***` in the output. `wuhu:secret` placeholders are refused in commands, `env` and stdin: only `fetch` fills one in.
