import { machine } from "wuhu:machine"

const box = machine("box")
const out = []
const clean = (message, id) => message.replace(id, "<id>").replace(/mc_\w+/, "<machine>")

const gone = await box.spawn("vanish", { stdin: true })
const lines = gone.lines()
out.push(`first: ${(await lines.next()).value.text}`)
await gone.write("go")
try {
  for await (const { text } of lines) out.push(`later: ${text}`)
} catch (error) {
  out.push(`lines: ${clean(error.message, gone.id)}`)
}
try {
  await gone.wait()
} catch (error) {
  out.push(`wait: ${clean(error.message, gone.id)}`)
}

// A loss after a cut fails the read: the bare \r left behind is no piece.
const cut = await box.spawn("vanish-after-cut")
try {
  for await (const { text } of cut.lines()) out.push(`cut piece: ${text.length}`)
} catch (error) {
  out.push(`cut lines: ${clean(error.message, cut.id)}`)
}

// The lost processes no longer hold one of the 8 slots.
const sleepers = []
for (let i = 0; i < 8; i++) sleepers.push(await box.spawn("sleep"))
out.push(`running after the loss: ${sleepers.length}`)
result(out.join("\n"))
