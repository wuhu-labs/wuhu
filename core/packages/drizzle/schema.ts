import {
  index,
  integer,
  pgEnum,
  pgTable,
  serial,
  text,
  timestamp,
  uniqueIndex,
} from 'drizzle-orm/pg-core'
import { createId } from './utils.ts'

export const sandboxStatus = pgEnum('sandbox_status', [
  'pending',
  'running',
  'terminating',
  'terminated',
  'failed',
])

export const sandboxes = pgTable('sandboxes', {
  id: text('id').primaryKey().$defaultFn(createId),
  name: text('name'),
  repoFullName: text('repo_full_name'),
  status: sandboxStatus('status').notNull().default('pending'),
  jobName: text('job_name').notNull().unique(),
  namespace: text('namespace').notNull(),
  podName: text('pod_name'),
  podIp: text('pod_ip'),
  daemonPort: integer('daemon_port').notNull().default(8787),
  previewPort: integer('preview_port').notNull().default(8066),
  createdAt: timestamp('created_at').notNull().defaultNow(),
  updatedAt: timestamp('updated_at').notNull().defaultNow().$onUpdate(() =>
    new Date()
  ),
  terminatedAt: timestamp('terminated_at'),
})

export const sessions = pgTable('sessions', {
  id: text('id').primaryKey().references(() => sandboxes.id),
  cursor: integer('cursor').notNull().default(0),
  createdAt: timestamp('created_at').notNull().defaultNow(),
  updatedAt: timestamp('updated_at').notNull().defaultNow().$onUpdate(() =>
    new Date()
  ),
})

export const messages = pgTable(
  'messages',
  {
    id: serial('id').primaryKey(),
    sessionId: text('session_id').notNull().references(() => sessions.id),
    cursor: integer('cursor').notNull(),
    role: text('role').notNull(),
    content: text('content').notNull(),
    toolName: text('tool_name'),
    toolCallId: text('tool_call_id'),
    turnIndex: integer('turn_index').notNull(),
    createdAt: timestamp('created_at').notNull().defaultNow(),
  },
  (table) => [
    uniqueIndex('messages_session_cursor_unique').on(
      table.sessionId,
      table.cursor,
    ),
    index('messages_session_cursor_idx').on(table.sessionId, table.cursor),
  ],
)
