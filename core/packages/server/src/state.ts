import { and, asc, eq, gt, sql } from 'drizzle-orm'
import type { Database } from '@wuhu/drizzle'
import { messages, sessions } from '@wuhu/drizzle'

export type PersistedMessageRole = 'user' | 'assistant' | 'tool'

export type PersistedMessageInput = {
  cursor: number
  role: PersistedMessageRole | string
  content: string
  toolName?: string | null
  toolCallId?: string | null
  turnIndex: number
}

export async function persistSandboxState(
  db: Database,
  sandboxId: string,
  state: { cursor: number; messages: PersistedMessageInput[] },
): Promise<{ cursor: number }> {
  const deduped = new Map<number, PersistedMessageInput>()
  for (const message of state.messages) {
    deduped.set(message.cursor, message)
  }
  const messageValues = Array.from(deduped.values()).map((message) => ({
    sessionId: sandboxId,
    cursor: message.cursor,
    role: message.role,
    content: message.content,
    toolName: message.toolName ?? null,
    toolCallId: message.toolCallId ?? null,
    turnIndex: message.turnIndex,
  }))

  const maxMessageCursor = messageValues.reduce(
    (acc, message) => Math.max(acc, message.cursor),
    0,
  )
  const cursor = Math.max(state.cursor, maxMessageCursor)

  await db.transaction(async (tx) => {
    await tx
      .insert(sessions)
      .values({ id: sandboxId, cursor, updatedAt: new Date() })
      .onConflictDoUpdate({
        target: sessions.id,
        set: {
          cursor: sql<number>`GREATEST(${sessions.cursor}, EXCLUDED.cursor)`,
          updatedAt: new Date(),
        },
      })

    if (messageValues.length === 0) return

    await tx
      .insert(messages)
      .values(messageValues)
      .onConflictDoUpdate({
        target: [messages.sessionId, messages.cursor],
        set: {
          role: sql<string>`EXCLUDED.role`,
          content: sql<string>`EXCLUDED.content`,
          toolName: sql<string | null>`EXCLUDED.tool_name`,
          toolCallId: sql<string | null>`EXCLUDED.tool_call_id`,
          turnIndex: sql<number>`EXCLUDED.turn_index`,
        },
      })
  })

  return { cursor }
}

export type FetchSandboxMessagesOptions = {
  cursorExclusive?: number
  limit?: number
}

export type FetchSandboxMessagesResult = {
  messages: Array<{
    cursor: number
    role: string
    content: string
    toolName: string | null
    toolCallId: string | null
    turnIndex: number
  }>
  cursor: number
  hasMore: boolean
}

export async function fetchSandboxMessages(
  db: Database,
  sandboxId: string,
  options?: FetchSandboxMessagesOptions,
): Promise<FetchSandboxMessagesResult> {
  const cursorExclusive = options?.cursorExclusive ?? 0
  const limit = options?.limit ?? 100
  const take = Math.max(0, limit) + 1

  const rows = await db
    .select({
      cursor: messages.cursor,
      role: messages.role,
      content: messages.content,
      toolName: messages.toolName,
      toolCallId: messages.toolCallId,
      turnIndex: messages.turnIndex,
    })
    .from(messages)
    .where(
      and(
        eq(messages.sessionId, sandboxId),
        gt(messages.cursor, cursorExclusive),
      ),
    )
    .orderBy(asc(messages.cursor))
    .limit(take)

  const hasMore = rows.length > limit
  const sliced = hasMore ? rows.slice(0, limit) : rows
  const nextCursor = sliced.length
    ? sliced[sliced.length - 1].cursor
    : cursorExclusive

  return { messages: sliced, cursor: nextCursor, hasMore }
}
