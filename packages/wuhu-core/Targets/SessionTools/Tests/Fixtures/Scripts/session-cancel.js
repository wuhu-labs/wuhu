import { cancel } from "wuhu:session"

// tc-1 is the timer the test armed before this script.
const out = []
for (const id of ["timer.tc-1", "timer.tc-1", "obs.nope", "0a1b2c3d", "script.ffffffff"]) {
  try {
    out.push(await cancel(id))
  } catch (error) {
    out.push({ code: error.code, message: error.message })
  }
}
result(JSON.stringify(out))
