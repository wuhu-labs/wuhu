import { machine } from "wuhu:machine"
import { secret, set } from "wuhu:secret"

const box = machine("box")
await set("API_KEY", "FAKE-KEY")
const raw = await box.spawn("upper", { stdin: true })
const text = await box.spawn("upper", { stdin: true })
const read = (items, render, separator) => {
  let seen
  const first = new Promise((resolve) => (seen = resolve))
  const all = (async () => {
    const out = []
    for await (const item of items) {
      out.push(render(item))
      seen()
    }
    return out.join(separator)
  })()
  return { first, all }
}
const rawRead = read(raw, ({ data }) => String.fromCharCode(...data), "")
const textRead = read(text.lines(), ({ text }) => text, "|")
raw.write("hi ")
text.write("hi\n")
await rawRead.first
await textRead.first
await fetch("https://api.example.test/", { method: "POST", body: secret("API_KEY") })
for (const process of [raw, text]) {
  process.write("fake-key")
  process.end()
}
result({ raw: await rawRead.all, lines: await textRead.all })
