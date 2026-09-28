// run_script v1 — reference sample, doubles as a conformance test.
//
// Called as
//
//   run_script({ source, timeout_seconds: 60, on_timeout: "detach" })
//
// What a v1 script has:
//
//   import { query, observe, watch, mutateRows, readAttributes, patchAttributes } from "wuhu:space"
//       query`SELECT … WHERE x = ${x}`    → Promise<Row[]>, rows are plain objects
//       Interpolations become bound parameters; they are never spliced into the SQL.
//       observe`…` yields every new snapshot, watch(glob) every file event;
//       leaving the loop (break, return, throw) closes the stream on the Swift side.
//       mutateRows, readAttributes and patchAttributes write as this session.
//
//   import.meta.session   the id of the session that called run_script
//
//   result(value)         the tool call's result. At most once.
//   update(value)         only after result(). Reaches the session later as a
//                         message, the way a timer message does.
//   signal                AbortSignal for this execution: stop_script, kill on
//                         timeout, max lifetime. Every host call observes it by
//                         default; pass { signal } to narrow it further.
//   sleep(ms)             host timer on the server clock. Rejects on abort.
//   fetch, Request, Response, Headers, AbortSignal.timeout / .any
//                         whole bodies only: text(), json(), arrayBuffer().
//   console               captured; its tail comes back if the script is killed.
//
// The execution is released on its own once the top level has finished and
// nothing is pending: no host call in flight, no timer, no open stream.
//
// This script is a night watch over my own child tasks:
//   1. it answers at once with a snapshot of the last 24 hours,
//   2. then sends an update whenever a child fails or finishes,
//   3. and ends by itself when no child is left running.

import { query } from "wuhu:space"

const me = import.meta.session
const hour = 3_600_000
const pinnedQuickJS = "v0.15.1"

// ── Snapshot ──────────────────────────────────────────────────────────────────

const since = new Date(Date.now() - 24 * hour).toISOString()

const [recent, quickjs] = await Promise.all([
  query`
    SELECT id, title, executor_config, run_state, error_message
    FROM sessions
    WHERE parent = ${me} AND last_activity_at > ${since}
    ORDER BY last_activity_at DESC
  `,
  latestRelease("quickjs-ng/quickjs"),
])

const byModel = Map.groupBy(recent, (s) => JSON.parse(s.executor_config).model)

result({
  children: recent.length,
  byModel: Object.fromEntries([...byModel].map(([model, xs]) => [model, xs.length])),
  failed: recent
    .filter((s) => s.error_message)
    .map(({ id, title, error_message }) => ({ id, title, error: error_message.slice(0, 200) })),
  quickjs: quickjs && {
    pinned: pinnedQuickJS,
    latest: quickjs.tag,
    behind: quickjs.tag !== pinnedQuickJS,
  },
})

// ── Watch ─────────────────────────────────────────────────────────────────────
// The tool call has returned by now. Everything below reaches the session
// as update() messages.

const watching = new Map()

for (const { id, title } of await query`
  SELECT id, title FROM sessions
  WHERE parent = ${me} AND lifecycle != 'archived' AND run_state != 'no_run'
`) {
  watching.set(id, title)
}

while (watching.size > 0) {
  await sleep(60_000) // stop_script lands here as an AbortError and ends the run

  const ids = JSON.stringify([...watching.keys()])

  for (const s of await query`
    SELECT id, run_state, error_message FROM sessions
    WHERE id IN (SELECT value FROM json_each(${ids}))
  `) {
    const title = watching.get(s.id)

    if (s.error_message) {
      update(`✗ ${title} failed: ${s.error_message.slice(0, 200)}`)
    } else if (s.run_state === "no_run") {
      update(`✓ ${title} is done`)
    } else {
      continue
    }

    watching.delete(s.id)
  }
}

update("No child is running any more. Watch over.")

// Falling off the end with nothing pending releases the execution.

// ── Helpers ───────────────────────────────────────────────────────────────────

async function latestRelease(repo) {
  const request = new Request(`https://api.github.com/repos/${repo}/releases/latest`, {
    headers: new Headers({
      "accept": "application/vnd.github+json",
      "user-agent": "wuhu-run-script",
    }),
    signal: AbortSignal.any([signal, AbortSignal.timeout(10_000)]),
  })

  const response = await fetch(request)

  if (!response.ok) {
    console.warn(`GitHub answered ${response.status} ${response.statusText}`)
    return null
  }

  const { tag_name: tag, published_at: published } = await response.json()
  return { tag, published: new Date(published) }
}
