import { area, meta } from "wuhu:/skills/geometry/area.js"
import { cyclic } from "wuhu:/skills/geometry/lib/unit.js"

let dynamic
try {
  await import("wuhu:/skills/geometry/area.js")
} catch (error) {
  dynamic = error.message
}
result(JSON.stringify({ area: area(3), cyclic: cyclic(), sameMeta: meta === import.meta.session, dynamic }))
