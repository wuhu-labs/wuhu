import { remove, set } from "wuhu:secret"

const outcomes = []
for (const attempt of [() => set("X", "v"), () => remove("X")]) {
  try {
    await attempt()
    outcomes.push("done")
  } catch (error) {
    outcomes.push(error.message)
  }
}
result(outcomes)
