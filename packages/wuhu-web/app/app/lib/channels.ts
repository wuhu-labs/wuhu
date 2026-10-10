import type { QueryOutput } from './contract.gen.ts'

export interface ChannelSummary {
  id: string
  title: string
  unread: boolean
}

export const channelsSQL = `SELECT c.id, COALESCE(c.title,
  (SELECT group_concat(member, ', ') FROM conversation_members WHERE conversation_id = c.id AND member_kind = 'user'), c.id),
  EXISTS (SELECT 1 FROM notifications n
    WHERE n.recipient = viewer() AND n.kind = 'conversation_message' AND n.source = c.id
      AND n.n > COALESCE((SELECT last_read_n FROM watermarks w WHERE w.identity = viewer() AND w.source = c.id), 0))
FROM conversations c WHERE c.kind = 'users' ORDER BY c.created_at, c.id`

export function channelRows(output: QueryOutput): ChannelSummary[] {
  return output.rows.map((row) => ({
    id: String(row[0]),
    title: String(row[1]),
    unread: row[2] === 1,
  }))
}
