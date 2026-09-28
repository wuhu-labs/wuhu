import { list, secret, set } from "wuhu:secret"

const outcomes = []
for (const attempt of [
  () => fetch(`https://api.example.test/${secret("K")}`),
  () => fetch(`https://api.example.test/${secret("K", { group: "alice" })}`),
  () => list({ group: "alice" }),
]) {
  try {
    await attempt()
    outcomes.push("fetched")
  } catch (error) {
    outcomes.push(error.message)
  }
}
await set("X", "shared-value")
result(outcomes)
