import { machine } from "wuhu:machine"
import { secret, set } from "wuhu:secret"

await set("API_KEY", "fake-key\n")
await fetch("https://api.example.test/", { method: "POST", body: secret("API_KEY") })
const split = await machine("box").spawn("split-secret")
const out = { out: "", err: "" }
for await (const { stream, data } of split) out[stream] += String.fromCharCode(...data)
result(out)
