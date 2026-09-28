import { query } from "wuhu:space"

try {
  await query`
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 65)
    SELECT i, zeroblob(1048576) AS megabyte FROM n
  `
  result("unreachable")
} catch (error) {
  result(`${error.name} ${error.code}: ${error.message}`)
}
