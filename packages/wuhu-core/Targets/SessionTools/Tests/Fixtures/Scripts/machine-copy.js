import { copy, machine } from "wuhu:machine"

const box = machine("box")
const out = []
await box.write("/work/a.txt", "payload\n")
const landed = await copy("machines://box/work/a.txt", "/copied/a.txt")
out.push(`to space: ${landed.bytes} bytes, ${landed.sha256}`)
try {
  await copy("machines://box/work/a.txt", "/copied/a.txt")
} catch (error) {
  out.push(`${error.code}: ${error.message}`)
}
await box.write("/work/a.txt", "payload, again\n", { ifMatch: (await box.stat("/work/a.txt")).token })
const replaced = await copy("machines://box/work/a.txt", "/copied/a.txt", { overwrite: true })
out.push(`replaced: ${replaced.bytes} bytes`)
const back = await copy("/copied/a.txt", "machines://box/work/b.txt")
out.push(`to machine: ${back.bytes} bytes, token ${back.token}`)
out.push(`text: ${JSON.stringify(await box.readText("/work/b.txt"))}`)
try {
  await copy("/copied/a.txt", "/elsewhere.txt")
} catch (error) {
  out.push(`${error.code}: ${error.message}`)
}
result(out.join("\n"))
