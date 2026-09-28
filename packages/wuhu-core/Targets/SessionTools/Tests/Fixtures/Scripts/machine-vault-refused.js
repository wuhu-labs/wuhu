import { list, set } from "wuhu:secret"

const outcomes = []
for (const attempt of [() => set("X", "v", { machine: "box" }), () => list({ machine: "box" })]) {
  try {
    outcomes.push((await attempt()) ?? "done")
  } catch (error) {
    outcomes.push(error.message)
  }
}
result(outcomes)
