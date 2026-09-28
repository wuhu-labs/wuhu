import { list, remove, secret, set } from "wuhu:secret"

const outcomes = []
for (const attempt of [
  () => set("TOKEN", "v1", { machine: "box" }),
  () => list({ machine: "box" }),
  () => list(),
  () => remove("TOKEN", { machine: "box" }),
  () => set("X", "v", { machine: "away" }),
  () => set("X", "v", { machine: "nowhere" }),
  () => list({ machine: "box", group: "shared" }),
  () => secret("TOKEN", { machine: "box" }),
]) {
  try {
    outcomes.push((await attempt()) ?? "done")
  } catch (error) {
    outcomes.push(error.message)
  }
}
result(outcomes)
