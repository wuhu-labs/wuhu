import { machine } from "wuhu:machine"
import { secret, set } from "wuhu:secret"

const box = machine("box")
const out = []
const attempt = async (label, run) => {
  try {
    await run()
    out.push(`${label}: ok`)
  } catch (error) {
    out.push(`${label}: ${error.message}`)
  }
}

await set("TOKEN", "hunter2")
await attempt("unknown machine", () => machine("nowhere").stat("/"))
await attempt("detached machine", () => machine("away").exec("true"))
await attempt("relative path", () => box.readText("notes.txt"))
await attempt("relative cwd", () => box.exec("true", { cwd: "work" }))
await attempt("placeholder in the command", () => box.exec(`curl -H ${secret("TOKEN")}`))
await attempt("placeholder in env", () => box.spawn("true", { env: { AUTH: `Bearer ${secret("TOKEN")}` } }))
await attempt("bad env name", () => box.exec("true", { env: { "A-B": "1" } }))

const talker = await box.spawn("upper", { stdin: true })
await attempt("placeholder on stdin", () => talker.write(secret("TOKEN")))
await talker.end()
await talker.wait()

const sleepers = []
for (let i = 0; i < 8; i++) sleepers.push(await box.spawn("sleep"))
await attempt("stdin not asked for", () => sleepers[0].write("x"))
await attempt("a ninth process", () => box.spawn("sleep"))
await sleepers[0].kill()
await sleepers[0].wait()
await attempt("once one exits", () => box.spawn("sleep"))
result(out.join("\n"))
