import { generateImage } from "wuhu:ai"

const twins = ["machines://mc_aaaaaaaa/tmp/twin.png", "machines://mc_aaaaaaaa/tmp/./twin.png", "/art/twin.png", "/art/twin.png"]
const batch = await Promise.allSettled(twins.map((destination) => generateImage(destination.startsWith("/") ? "space twin" : "machine twin", { destination })))
const failed = await generateImage("forbidden", { destination: "machines://mc_aaaaaaaa/tmp/retry.png" }).catch((error) => error.message)
const retried = await generateImage("retry", { destination: "machines://mc_aaaaaaaa/tmp/retry.png" })
result({
  batch: batch.map((outcome) => outcome.status === "fulfilled" ? outcome.value.path : outcome.reason.message).sort(),
  failed,
  retried: retried.path,
})
