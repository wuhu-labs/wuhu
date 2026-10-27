---
name: monitor
description: Watch something on a machine from run_script — a log, a build, a long command — and get one message per event instead of polling. Covers result() then update(), the tail -F | grep pattern, batching, run-until-exit with a verdict, and stopping cleanly.
---

# Monitoring a machine from run_script

Read [machine-scripts](wuhu://system/skills/machine-scripts/SKILL.md) for the machine and Process contracts, and [script-runtime](wuhu://system/skills/script-runtime/SKILL.md) for cancellable sleep.

A monitor is a `run_script` module that starts a process on a machine with `wuhu:machine`'s `spawn`, answers the tool call at once, and then sends you one `update()` per event. Each update reaches you later as a message, so you stop polling: the space wakes you when something happens.

The shape is always the same:

1. `result(...)` right away, before the long wait. It answers the `run_script` call; until you call it, the call waits (up to `wait_seconds`, then it returns `running` and the script runs on).
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
- Pass `max_lifetime_seconds` to `run_script` for anything that should outlive the default hour. When the lifetime runs out, the script and its processes are killed and you get a notice.
- A job that has to outlive the script, or run past exec's 4-hour cap, is started detached by `exec`, not held in one: `setsid nohup make test > /tmp/test.log 2>&1 & echo $!` returns the PID at once, and this monitor tails `/tmp/test.log`. A plain `exec` is killed after 30 minutes by default, and its `max_lifetime_seconds` goes no higher than 4 hours.

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

## Stopping

Cancel the script id (`script.…` in `<session-state>`) to stop the monitor and its processes. A detached job is separate: keep its PID and stop it explicitly if the job, not just the monitor, should end. Re-run a monitor after a server restart if it is still needed.
