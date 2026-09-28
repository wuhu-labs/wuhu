import { generateImage } from "wuhu:ai"

const calls = [
  ["fine", { destination: "/art/fine.png" }],
  ["forbidden", { destination: "/art/forbidden.png" }],
  ["kept", { destination: "/art/kept.png" }],
  ["elsewhere", { destination: "/_/sessions/someone-else/elsewhere.png" }],
  ["nowhere", { destination: "machines://nowhere/tmp/x.png" }],
  ["relative", { destination: "art/relative.png" }],
  ["bare", undefined],
]
const outcomes = await Promise.allSettled(calls.map(([prompt, options]) => generateImage(prompt, options)))
result(outcomes.map((outcome) => (outcome.status === "fulfilled" ? outcome.value : `${outcome.reason.name}: ${outcome.reason.message}`)))
