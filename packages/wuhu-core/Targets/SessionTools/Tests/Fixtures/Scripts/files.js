import { move, remove } from "wuhu:space"

const home = `/_/sessions/${import.meta.session}`
const outcomes = []
const attempt = async (label, body) => {
  try {
    outcomes.push(`${label}: ${JSON.stringify(await body())}`)
  } catch (error) {
    outcomes.push(`${label}: ${error.message.replaceAll(import.meta.session, "<self>")}`)
  }
}

await attempt("onto an existing file", () => move(`${home}/candidate.png`, `${home}/avatar.png`))
await attempt("replacing it", () => move(`${home}/candidate.png`, `${home}/avatar.png`, { replace: true }))
await attempt("replacing a folder", () => move("/notes/a.md", "/folder", { replace: true }))
await attempt("to a free path", () => move("/notes/a.md", "/notes/b.md"))
await attempt("into another home", () => move("/notes/b.md", "/_/sessions/other/b.md"))
await attempt("out of another home", () => move("/_/sessions/other/note.md", "/notes/c.md"))
await attempt("remove", () => remove("/notes/b.md"))
await attempt("remove again", () => remove("/notes/b.md"))
await attempt("remove in another home", () => remove("/_/sessions/other/note.md"))
await attempt("remove a machine path", () => remove("machines://box/tmp/x"))
result(outcomes.join("\n"))
