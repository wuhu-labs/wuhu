import { query } from "wuhu:space"

// Each row holds 648 bytes against a 1 MB budget and 320 KB bodies. A query
// result is read whole and handed to the script, so only unread bodies and
// machine output stay held.
const rows = (n) => query`
  WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ${n})
  SELECT i, zeroblob(640) AS blob FROM n
`
const log = []
const attempt = async (label, action) => {
  try {
    await action()
    log.push(`${label}: ok`)
  } catch (error) {
    log.push(`${label}: ${error.message}`)
  }
}

const bodies = []
await attempt("1000 rows", () => rows(1000))
await attempt("a body after them", async () => bodies.push(await fetch("https://example.test/twenty")))
await attempt("another body", async () => bodies.push(await fetch("https://example.test/twenty")))
await attempt("1000 rows beside both", () => rows(1000))
await attempt("500 rows beside both", () => rows(500))
await attempt("a third body", async () => bodies.push(await fetch("https://example.test/twenty")))
await attempt("a fourth body", () => fetch("https://example.test/twenty"))
await attempt("reading every body", async () => {
  for (const body of bodies) await body.text()
})
await attempt("1000 rows once they are read", () => rows(1000))
result(log.join("\n"))
