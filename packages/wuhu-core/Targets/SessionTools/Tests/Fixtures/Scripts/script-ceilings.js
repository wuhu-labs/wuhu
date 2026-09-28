import { machine } from "wuhu:machine"

// A wait too long for any clock is clamped, not converted.
const never = AbortSignal.timeout(1e300)
// An exec timeout stops at this script's max lifetime, fraction and all.
const exec = await machine("box").exec("env", { timeout: 1e300 })
result(`${exec.stderr.trim()}; aborted: ${never.aborted}`)
