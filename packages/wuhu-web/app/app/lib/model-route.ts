import type { QueryOutput } from './contract.gen.ts'

// The group member a session runs on. `reason` is the latest placement
// decision's reason as the server wrote it; unknown reasons render verbatim.
export interface SessionRoute {
  group: string
  member: string
  phase: string
  epoch: string
  reason: string | null
  previousMember: string | null
  // Changes whenever the server rewrites the open failure without moving the
  // route; readers refetch the failure on a change.
  failureRevision: string | null
}

// `previous_member` is the member of the decision before the latest one, and
// only when that decision placed the same group.
export const sessionRoutesSQL =
  `SELECT r.session_id, r.group_id, r.member_id, r.phase, r.route_epoch,
  (SELECT h.reason FROM session_model_route_history h WHERE h.session_id = r.session_id ORDER BY h.decision_id DESC LIMIT 1) AS reason,
  (SELECT h.member_id FROM session_model_route_history h WHERE h.session_id = r.session_id AND h.group_id = r.group_id
    AND h.decision_id < (SELECT MAX(l.decision_id) FROM session_model_route_history l WHERE l.session_id = r.session_id)
    ORDER BY h.decision_id DESC LIMIT 1) AS previous_member,
  json_extract(r.payload, '$.failure') AS failure_revision
FROM session_model_routes r
WHERE r.group_id IS NOT NULL AND r.member_id IS NOT NULL`

export function withRoutes<Row extends { id: string }>(
  rows: Row[] | null,
  routes: ReadonlyMap<string, SessionRoute>,
): (Row & { route?: SessionRoute })[] | null {
  return rows?.map((row) => {
    const route = routes.get(row.id)
    return route == null ? row : { ...row, route }
  }) ?? null
}

function text(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

export function routeRows(output: QueryOutput): Map<string, SessionRoute> {
  const routes = new Map<string, SessionRoute>()
  for (const row of output.rows) {
    const [id, group, member] = [text(row[0]), text(row[1]), text(row[2])]
    if (id == null || group == null || member == null) continue
    routes.set(id, {
      group,
      member,
      phase: text(row[3]) ?? '',
      epoch: text(row[4]) ?? '',
      reason: text(row[5]),
      previousMember: text(row[6]),
      failureRevision: text(row[7]),
    })
  }
  return routes
}
