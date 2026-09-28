import { conversation, dm } from "wuhu:space"
import { foreign, helper, ours, theirs } from "wuhu:/fixture/ids.js"

const me = import.meta.session
const lines = []
const ids = (page) => `${page.messages.map((message) => message.id).join(" ")} next=${page.next}`
const attempt = async (label, call) => {
  try {
    lines.push(`${label}: ${ids(await call())}`)
  } catch (error) {
    lines.push(`${label}: ${error.message}`)
  }
}

const latest = await conversation(me)
lines.push(JSON.stringify(latest.messages.slice(0, 2), null, 2))
lines.push(`m5 createdAt: ${latest.messages[4].createdAt}`)

await attempt("latest 2", () => conversation(me, { limit: 2 }))
await attempt("before m4", () => conversation(me, { before: "m4", limit: 2 }))
await attempt("before m2", () => conversation(me, { before: "m2", limit: 2 }))
await attempt("after m1", () => conversation(me, { after: "m1", limit: 3 }))
await attempt("after m3", () => conversation(me, { after: "m3" }))
await attempt("after 08:00+08:00", () => conversation(me, { after: "2001-01-01T08:00+08:00" }))
await attempt("after 07:59:59.999+08:00", () => conversation(me, { after: "2001-01-01T07:59:59.999+08:00" }))
await attempt("before 00:01Z", () => conversation(me, { before: "2001-01-01T00:01Z" }))
await attempt("after a Date", () => conversation(me, { after: new Date("2001-01-01T00:00:30Z") }))
await attempt("after its own createdAt", () => conversation(me, { after: latest.messages[4].createdAt }))

const walked = []
let cursor = "2000-12-31T23:59Z"
for (;;) {
  const page = await conversation(me, { after: cursor, limit: 1 })
  walked.push(...page.messages.map((message) => message.id))
  if (page.next === null) break
  cursor = page.next
}
lines.push(`one at a time: ${walked.join(" ")}`)

const direct = await dm(me, helper)
lines.push(`dm: ${direct === (await dm(helper, me))} ${ids(await conversation(direct))}`)
lines.push(`no dm: ${await dm(me, "nobody-at-all")} ${await dm(me, me)}`)

await attempt("a group I am in", () => conversation(ours))
await attempt("a group I am not in", () => conversation(theirs))
await attempt("unknown message", () => conversation(me, { after: "m-missing" }))
await attempt("message elsewhere", () => conversation(me, { after: "d1" }))
await attempt("both cursors", () => conversation(me, { after: "m1", before: "m3" }))
await attempt("limit 0", () => conversation(me, { limit: 0 }))
await attempt("limit 501", () => conversation(me, { limit: 501 }))
await attempt("no zone", () => conversation(me, { after: "2026-09-26T11:00" }))
await attempt("unknown conversation", () => conversation("no-such-box"))
await attempt("a box in an unread group", () => conversation(foreign))
await attempt("no id", () => conversation(null))

result(lines.join("\n"))
