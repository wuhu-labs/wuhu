import { machine } from "wuhu:machine"

// Nothing awaits the process, so the script ends here and takes it along.
const sleeper = await machine("box").spawn("sleep")
result(`spawned ${sleeper.id}`)
