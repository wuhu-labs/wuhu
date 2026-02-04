import { assert, assertEquals } from '@std/assert'
import { and, eq, sql } from 'drizzle-orm'
import { drizzle } from 'drizzle-orm/postgres-js'
import { migrate } from 'drizzle-orm/postgres-js/migrator'
import postgres from 'postgres'
import type { Database } from '@wuhu/drizzle'
import * as schema from '@wuhu/drizzle/schema'
import { messages, sandboxes, sessions } from '@wuhu/drizzle/schema'
import { fetchSandboxMessages, persistSandboxState } from './state.ts'

const migrationsFolder = new URL(
  '../../drizzle/migrations',
  import.meta.url,
).pathname

async function withTestDb(
  fn: (db: Database) => Promise<void>,
): Promise<void> {
  const connectionString = Deno.env.get('DATABASE_URL')
  if (!connectionString) {
    throw new Error('DATABASE_URL is required to run server DB tests')
  }

  const client = postgres(connectionString, { max: 1 })
  const db = drizzle(client, { schema }) as unknown as Database

  try {
    await migrate(db, { migrationsFolder })
    await fn(db)
  } finally {
    await client.end({ timeout: 5 })
  }
}

Deno.test('DB state API persistence is idempotent + paginates', async () => {
  await withTestDb(async (db) => {
    const sandboxId = `sb_${crypto.randomUUID().slice(0, 12)}`

    await db
      .delete(messages)
      .where(eq(messages.sessionId, sandboxId))
    await db
      .delete(sessions)
      .where(eq(sessions.id, sandboxId))
    await db
      .delete(sandboxes)
      .where(eq(sandboxes.id, sandboxId))

    await db.insert(sandboxes).values({
      id: sandboxId,
      jobName: `job_${sandboxId}`,
      namespace: 'test',
    })

    await persistSandboxState(db, sandboxId, {
      cursor: 2,
      messages: [
        { cursor: 1, role: 'user', content: 'fix auth', turnIndex: 1 },
        { cursor: 2, role: 'assistant', content: 'ok', turnIndex: 1 },
      ],
    })

    const initial = await fetchSandboxMessages(db, sandboxId, {
      cursorExclusive: 0,
      limit: 100,
    })
    assertEquals(initial.messages.map((message) => message.cursor), [1, 2])
    assertEquals(initial.cursor, 2)
    assertEquals(initial.hasMore, false)

    await persistSandboxState(db, sandboxId, {
      cursor: 2,
      messages: [
        { cursor: 2, role: 'assistant', content: 'updated', turnIndex: 1 },
      ],
    })

    const afterUpsert = await fetchSandboxMessages(db, sandboxId, {
      cursorExclusive: 0,
      limit: 100,
    })
    assertEquals(afterUpsert.messages.length, 2)
    assertEquals(
      afterUpsert.messages.find((message) => message.cursor === 2)?.content,
      'updated',
    )

    await persistSandboxState(db, sandboxId, {
      cursor: 6,
      messages: [
        { cursor: 3, role: 'assistant', content: 'm3', turnIndex: 1 },
        { cursor: 4, role: 'assistant', content: 'm4', turnIndex: 1 },
        { cursor: 5, role: 'assistant', content: 'm5', turnIndex: 1 },
        { cursor: 6, role: 'assistant', content: 'm6', turnIndex: 1 },
      ],
    })

    const page1 = await fetchSandboxMessages(db, sandboxId, {
      cursorExclusive: 0,
      limit: 2,
    })
    assertEquals(page1.messages.map((message) => message.cursor), [1, 2])
    assert(page1.hasMore)

    const page2 = await fetchSandboxMessages(db, sandboxId, {
      cursorExclusive: page1.cursor,
      limit: 2,
    })
    assertEquals(page2.messages.map((message) => message.cursor), [3, 4])

    const page3 = await fetchSandboxMessages(db, sandboxId, {
      cursorExclusive: page2.cursor,
      limit: 10,
    })
    assertEquals(page3.messages.map((message) => message.cursor), [5, 6])
    assertEquals(page3.hasMore, false)

    await persistSandboxState(db, sandboxId, { cursor: 10, messages: [] })
    const session = await db
      .select({ cursor: sessions.cursor })
      .from(sessions)
      .where(eq(sessions.id, sandboxId))
      .limit(1)
    assertEquals(session[0]?.cursor, 10)

    const messageCount = await db
      .select({ count: sql<number>`count(*)`.mapWith(Number) })
      .from(messages)
      .where(eq(messages.sessionId, sandboxId))
    assertEquals(messageCount[0]?.count, 6)

    // Cleanup
    await db
      .delete(messages)
      .where(eq(messages.sessionId, sandboxId))
    await db
      .delete(sessions)
      .where(eq(sessions.id, sandboxId))
    await db
      .delete(sandboxes)
      .where(
        and(
          eq(sandboxes.id, sandboxId),
          eq(sandboxes.jobName, `job_${sandboxId}`),
        ),
      )
  })
})
