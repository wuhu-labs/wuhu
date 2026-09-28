import { mutateRows, observe, patchAttributes, query, readAttributes, watch } from "wuhu:space"

const log = []
const attempt = async (label, body) => {
  try {
    log.push(`${label}: ${JSON.stringify(await body())}`)
  } catch (error) {
    const token = error.token === undefined ? "" : " (carries the current token)"
    log.push(`${label}: ${error.name} ${error.code}: ${error.message.replaceAll(import.meta.session, "<self>")}${token}`)
  }
}

const rows = await query`SELECT title, meta, done, X'0107' AS data FROM "/tasks.table" WHERE title <> ${"skip"} ORDER BY id`
log.push(`query resolves to an array: ${Array.isArray(rows)}`)
log.push(`rows: ${JSON.stringify(rows)}`)
log.push(`bytes: ${rows[0].data instanceof Uint8Array} ${[...rows[0].data]}`)

const snapshots = observe("SELECT title FROM \"/tasks.table\" WHERE done = ? ORDER BY id", [true])[Symbol.asyncIterator]()
log.push(`first snapshot: ${JSON.stringify((await snapshots.next()).value)}`)

const { rev, ids } = await mutateRows("/tasks.table", [
  { insert: { title: "new", meta: { tags: ["x"] }, done: true } },
  { update: 1, set: { done: false } },
])
log.push(`inserted ids: ${JSON.stringify(ids)}`)
log.push(`next snapshot: ${JSON.stringify((await snapshots.next()).value)}`)
await snapshots.return()

const { attributes, token } = await readAttributes("/notes/plan.md")
log.push(`attributes: ${JSON.stringify(attributes)}`)
await attempt("patch", async () => typeof (await patchAttributes("/notes/plan.md", { set: { status: "done" }, remove: ["draft"], ifMatch: token })).token)
await attempt("patch with the stale token", () => patchAttributes("/notes/plan.md", { set: { status: "x" }, ifMatch: token }))

for await (const event of watch("/notes/**", { from: rev })) {
  log.push(`watched: ${event.kind} ${event.path}`)
  break
}

await attempt("a row in another home", () => mutateRows("/_/sessions/other/t.table", [{ insert: { title: "x" } }]))
await attempt("an unknown column", () => mutateRows("/tasks.table", [{ insert: { nope: 1 } }]))
await attempt("a missing table", () => query`SELECT * FROM "/missing.table"`)
await attempt("a non-Markdown file", () => readAttributes("/tasks.table"))
await attempt("a row by the qualified path", async () => {
  await mutateRows("wuhu://shared.localspace/tasks.table", [{ update: ids[0], set: { title: "renamed" } }])
  return (await query`SELECT title FROM "wuhu://shared.localspace/tasks.table" WHERE id = ${ids[0]}`)[0].title
})
await attempt("delete", async () => (await mutateRows("/tasks.table", [{ delete: ids[0] }])).ids)
log.push(`titles: ${(await query`SELECT title FROM "/tasks.table" ORDER BY id`).map((row) => row.title).join(", ")}`)
result(log.join("\n"))
