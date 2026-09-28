import { archive, createSession, interrupt, request, resume, setTags, unarchive } from "wuhu:session"
import { query } from "wuhu:space"

const me = import.meta.session
const who = (id) => (id === me ? "me" : id === null ? null : "someone else")
const shape = async (id) => {
  for (const row of await query`SELECT kind, parent, created_by, title, tags FROM sessions WHERE id = ${id}`) {
    return { kind: row.kind, parent: who(row.parent), createdBy: who(row.created_by), title: row.title, tags: JSON.parse(row.tags) }
  }
}
const names = new Map([[me, "<me>"]])
const scrub = (text) => [...names].reduce((out, [id, name]) => out.replaceAll(id, name), text)
const settle = (promise) => promise.then(
  (value) => value ?? "done",
  (error) => scrub(`${error.name}: ${error.message}`),
)
let stranger
for (const row of await query`SELECT id FROM sessions WHERE title = 'stranger'`) stranger = row.id
names.set(stranger, "<stranger>")

const out = {}
const helper = await createSession({
  title: "  helper  ", kind: "agent", tags: ["a"], message: "brief", expectsReply: true, key: "helper",
})
out.helper = { ...(await shape(helper.id)), requestId: typeof helper.requestId }
const again = await createSession({ title: "helper, again", key: "helper" })
out.sameKey = again.id === helper.id && again.requestId === helper.requestId
const unkeyed = [await createSession({ title: "twin" }), await createSession({ title: "twin" })]
out.unkeyedTwins = unkeyed[0].id !== unkeyed[1].id

const infra = await createSession({ title: "Wuhu Infra", topLevel: true, message: "your brief" })
names.set(infra.id, "<infra>")
out.infra = { ...(await shape(infra.id)), requestId: infra.requestId ?? null }
out.archiveInfra = await settle(archive(infra.id))
out.retagInfra = await settle(setTags(infra.id, ["mine"]))
out.requestInfra = await settle(request(infra.id, "report to me"))
out.topLevelReply = await settle(createSession({ title: "x", topLevel: true, expectsReply: true, message: "m" }))
out.badTitle = await settle(createSession({ title: "two\nlines" }))
out.noTitle = await settle(createSession({ kind: "agent" }))
out.noOptions = await settle(createSession())

const worker = unkeyed[0]
await setTags(worker.id, ["wuhu:13", "gate"])
out.retagged = (await shape(worker.id)).tags
out.request = typeof (await request(worker.id, "do it", { deadlineSeconds: 600 })).requestId
out.verbs = [
  await settle(interrupt(worker.id)),
  await settle(resume(worker.id)),
  await settle(archive(worker.id)),
  await settle(unarchive(worker.id)),
  await settle(setTags(me, ["self"])),
]
out.stranger = [await settle(archive(stranger)), await settle(setTags(stranger, ["x"]))]
out.unknown = await settle(interrupt("no-such-session"))
result(out)
