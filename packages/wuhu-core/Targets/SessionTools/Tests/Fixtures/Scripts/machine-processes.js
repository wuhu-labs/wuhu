import { machine, machines } from "wuhu:machine"

const box = machine("box")
const out = []
out.push(`machines: ${JSON.stringify((await machines()).map(({ name, attached }) => ({ name, attached })))}`)

const build = await box.spawn("build")
for await (const { stream, text } of build.lines()) out.push(`${stream}: ${text}`)
out.push(`build: ${JSON.stringify(await build.wait())}`)
try {
  build.lines()
} catch (error) {
  out.push(error.message.replace(build.id, "<id>"))
}

const raw = await box.spawn("bytes")
for await (const { stream, data } of raw) out.push(`${stream}: ${Array.from(data).join(",")}`)

const upper = await box.spawn("upper", { stdin: true })
upper.write("hello ")
upper.write(new Uint8Array([119, 111, 114, 108, 100]))
upper.end()
for await (const { text } of upper.lines()) out.push(`upper: ${text}`)

const env = await box.exec("env", {
  cwd: "/work",
  env: { CI: "1" },
  secrets: { TOKEN: "GITHUB_TOKEN" },
  timeout: 1500,
})
out.push(`exec: ${JSON.stringify(env)}`)

// 3 MiB with no newline: the reader gets it in window-sized pieces, and the
// machine sends past the first MiB only as those are taken.
const flood = await box.spawn("flood")
const pieces = []
for await (const { text } of flood.lines()) pieces.push(text.length)
out.push(`flood: ${pieces.join(", ")}`)

const sleeper = await box.spawn("sleep")
await sleeper.kill()
out.push(`killed: ${JSON.stringify(await sleeper.wait())}`)
try {
  await build.write("x")
} catch (error) {
  out.push(error.message.replace(build.id, "<id>"))
}
result(out.join("\n"))
