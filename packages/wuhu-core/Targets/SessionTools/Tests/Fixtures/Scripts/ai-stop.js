import { generateImage } from "wuhu:ai"

result("generating")
const names = ["a", "b", "c", "d", "e", "f"]
const outcomes = await Promise.allSettled(names.map((name) => generateImage(name, { destination: `/art/${name}.png` })))
update(outcomes.map((outcome) => `${outcome.status}: ${outcome.reason?.name}: ${outcome.reason?.message}`))
