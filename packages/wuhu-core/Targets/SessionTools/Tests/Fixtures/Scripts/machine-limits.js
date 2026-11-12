import { machine } from "wuhu:machine"

const box = machine("box")
const out = []

// The agent stops at maxOutput; the answer says so.
const cut = await box.exec("noisy", { maxOutput: 10 })
out.push(`maxOutput 10: ${JSON.stringify(cut)}`)
// Numbers too big for an integer are clamped, not converted.
const huge = await box.exec("noisy", { maxOutput: 1e20 })
out.push(`maxOutput 1e20: ${JSON.stringify(huge)}`)
const late = await box.exec("env", { timeout: 1e300 })
out.push(`timeout 1e300: ${late.stderr.trim()}`)

// A reader that leaves early drops the rest: the 3 MiB flood runs to its exit
// instead of stalling on a full window.
const flood = await box.spawn("flood")
for await (const { text } of flood.lines()) {
  out.push(`flood, first piece: ${text.length}`)
  break
}
out.push(`flood after the break: ${JSON.stringify(await flood.wait())}`)
result(out.join("\n"))
