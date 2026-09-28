import { list, remove, secret, set } from "wuhu:secret"

await set("GITHUB_TOKEN", "ghp_live_value")
await set("UNUSED", "never-sent")
const token = secret("GITHUB_TOKEN")
const encoded = encodeURIComponent(token)
const response = await fetch(`https://api.example.test/check/${encoded}?key=${encoded}`, {
  method: "POST",
  headers: { authorization: `Bearer ${token}` },
  body: `token=${encoded}&note=${encodeURIComponent("a b")}`,
})
const echoed = await response.text()
let removal
try {
  await remove("UNUSED")
} catch (error) {
  removal = error.message
}
let refused
try {
  secret("not a name")
} catch (error) {
  refused = error.message
}
result({ names: await list(), token, echoed, header: response.headers.get("server"), url: response.url, refused, removal, unused: "never-sent" })
console.log("the echo was", echoed)
throw new Error(`still ${echoed}`)
