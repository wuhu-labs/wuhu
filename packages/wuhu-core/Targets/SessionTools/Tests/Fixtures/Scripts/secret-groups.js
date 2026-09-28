import { list, secret, set } from "wuhu:secret"

await set("K", "alice-value")
const own = secret("K")
const shared = secret("K", { group: "shared" })
const response = await fetch(`https://api.example.test/${own}/${shared}`)
result({ names: await list(), sharedNames: await list({ group: "shared" }), own, shared, echoed: await response.text() })
