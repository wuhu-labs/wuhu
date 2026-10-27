import type { Space } from './space-core.d.ts'

export { SpaceError } from './space-core.d.ts'

export const query: Space['query']
export const observe: Space['observe']
export const watch: Space['watch']
export const mutateRows: Space['mutateRows']
export const readAttributes: Space['readAttributes']
export const patchAttributes: Space['patchAttributes']
export const find: Space['find']
export const grep: Space['grep']

export function createSession(options: {
  title: string
  kind?: 'agent'
  group?: string
  executor?: string
  provider?: string
  model?: string
  modelGroup?: string
  effort?: string
  template?: string
  tags?: string[]
  message?: string
  key?: string
  expectsReply?: boolean
  stallSeconds?: number
  request?: {
    kind?: string
    key?: string
    schema?: unknown
    fields?: Record<string, unknown>
  }
}): Promise<{
  id: string
  requestId?: string
  existing?: boolean
  modelGroup?: string
  member?: string
  provider?: string
  model?: string
}>
export function sendMessage(options: {
  message: string
  conversation?: string
  session?: string
  reply_target?: string
  attachments?: string[]
}): Promise<{ messageId: string; conversationId: string }>

export const fetch: typeof globalThis.fetch
