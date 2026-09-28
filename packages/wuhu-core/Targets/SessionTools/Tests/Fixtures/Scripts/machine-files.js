import { machine } from "wuhu:machine"

const box = machine("box")
const out = []
out.push(`written: ${await box.write("/work/notes.txt", "first line\n")}`)
const stat = await box.stat("/work/notes.txt")
out.push(`stat: ${stat.kind} ${stat.size} bytes, token ${stat.token}, ${stat.mtime.toISOString()}`)
out.push(`missing: ${await box.stat("/work/nope.txt")}`)
out.push(`text: ${JSON.stringify(await box.readText("/work/notes.txt"))}`)
await box.write("/work/blob.bin", new Uint8Array([0xff, 0xfe, 0x41]))
out.push(`bytes: ${Array.from(await box.read("/work/blob.bin")).join(",")}`)
try {
  await box.readText("/work/blob.bin")
} catch (error) {
  out.push(error.message)
}
await box.move("/work/blob.bin", "/work/old/blob.bin")
out.push(`list: ${(await box.list("/work")).map(({ name, kind }) => `${name} (${kind})`).join(", ")}`)
await box.remove("/work/old")
try {
  await box.remove("/work/old")
} catch (error) {
  out.push(error.message)
}
out.push(`after remove: ${(await box.list("/work")).map(({ name }) => name).join(", ")}`)
result(out.join("\n"))
