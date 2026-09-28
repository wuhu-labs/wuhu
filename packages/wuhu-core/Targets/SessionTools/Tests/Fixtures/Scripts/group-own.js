import { move, remove } from "wuhu:space"
import { where as own } from "wuhu:/skills/lib.js"
import { where as common } from "wuhu://shared.localspace/skills/lib.js"

const moved = await move("/draft.md", "wuhu://shared.localspace/published.md")
const removed = await remove("wuhu://shared.localspace/old.md")
result({ own, common, moved: typeof moved.rev, removed: typeof removed.rev })
