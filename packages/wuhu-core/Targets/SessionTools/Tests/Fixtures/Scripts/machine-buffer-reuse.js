import { machine } from "wuhu:machine"

const box = machine("box")
let waited = 0
for (let i = 0; i < 3; i++) {
  const build = await box.spawn("build")
  if ((await build.wait()).code === 0) waited++
}
result(`spawned and waited unread: ${waited}`)
