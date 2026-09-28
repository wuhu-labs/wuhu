import { api, inGroup, post } from './http'
import { requireAISharing } from '~/lib/ai-sharing'
import type {
  SessionCompactInput,
  SessionContext,
  SessionContextOutput,
  SessionCreateInput,
  SessionCreateOutput,
  SessionHomeOutput,
  SessionRestartInput,
  SessionRestartOutput,
} from '~/lib/contract.gen'

export interface Attachment {
  kind: 'image' | 'file'
  path: string
  mimeType: string
  size?: number | null
}

export interface MessageContent {
  text: string
  attachments?: Attachment[]
}

export interface Sender {
  id: string
  timeZone: string
}

export interface DirectMessage {
  id: string
  sender: Sender
  timestamp: number
  content: MessageContent
}

export interface ConversationMessageItem {
  id: string
  messageID: string
  conversationID: string
  sender: Sender
  senderSession?: string | null
  timestamp: number
  kind: 'message' | 'request' | 'progress' | 'final'
  requestID?: string | null
  deadline?: number | null
  replyTarget?: string | null
  owesReply: boolean
  content: MessageContent
}

export type NotificationKind =
  | 'timer'
  | 'spaceObservation'
  | 'compactRequest'
  | 'owedReply'
  | 'parkReminder'
  | 'childFailed'
  | 'requestDeadline'
  | 'script'
  | 'context'

export interface SystemNotification {
  id: string
  timestamp: number
  kind: NotificationKind
  subscriptionID: string
  endsSubscription: boolean
  conversations: string[]
  requestID?: string | null
  content: MessageContent
}

export type ContentBlock =
  | { text: { text: string } }
  | {
    reasoning: {
      unencrypted?: string | null
      summary?: string | null
      redacted: boolean
    }
  }
  | { tool_call: { id: string; name: string; arguments: unknown } }
  | { hosted_tool: { type: string; action: string } }
  | { media: { url: string; mimeType: string } }

export interface AssistantEntry {
  id: string
  timestamp: number
  content: ContentBlock[]
  stopReason: string
  usage: { input_tokens: number; output_tokens: number; total_tokens: number }
}

export interface ToolResultItem {
  id: string
  timestamp: number
  provenance: { toolCall: { _0: string } } | {
    compactionReestablishment: Record<string, never>
  }
  payload: Record<string, unknown>
}

export interface BookmarkMarker {
  id: string
  timestamp: number
  name?: string | null
  toolCallID?: string | null
}

export interface GenerationHead {
  id: string
  timestamp: number
  summary: string
  note?: string | null
}

export type TranscriptItem =
  | { kind: 'direct'; value: DirectMessage }
  | { kind: 'message'; value: ConversationMessageItem }
  | { kind: 'notification'; value: SystemNotification }
  | { kind: 'assistant'; value: AssistantEntry }
  | { kind: 'toolResult'; value: ToolResultItem }
  | { kind: 'bookmark'; value: BookmarkMarker }
  | { kind: 'generationHead'; value: GenerationHead }

// Default JSONEncoder dates: seconds since 2001-01-01.
export function swiftDate(seconds: number): Date {
  return new Date((seconds + 978307200) * 1000)
}

export function browserTimezone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone
}

// A person creates in the group the request acts in.
export async function createSession(
  input: SessionCreateInput,
  group: string,
): Promise<SessionCreateOutput> {
  await requireAISharing()
  return post('/v1/session', input, inGroup(group))
}

// Every session route answers only in a group that reads the session's; the
// session's own always does.
export interface SessionAddress {
  id: string
  group: string
}

export async function archiveSession(session: SessionAddress): Promise<void> {
  await api(`/v1/session/${session.id}/archive`, {
    method: 'POST',
    headers: inGroup(session.group),
  })
}

export async function unarchiveSession(
  session: SessionAddress,
): Promise<void> {
  await requireAISharing()
  await api(`/v1/session/${session.id}/unarchive`, {
    method: 'POST',
    headers: inGroup(session.group),
  })
}

export async function fetchSessionContext(
  session: SessionAddress,
): Promise<SessionContext | null> {
  const output = await api<SessionContextOutput>(
    `/v1/session/${session.id}/context`,
    { headers: inGroup(session.group) },
  )
  return output.context ?? null
}

export function fetchSessionHome(
  session: SessionAddress,
): Promise<SessionHomeOutput> {
  return api(`/v1/session/${session.id}/home`, {
    headers: inGroup(session.group),
  })
}

export async function compactSession(
  session: SessionAddress,
  instructions: string,
): Promise<void> {
  await requireAISharing()
  const input: SessionCompactInput = instructions.trim() === ''
    ? {}
    : { instructions: instructions.trim() }
  await post(
    `/v1/session/${session.id}/compact`,
    input,
    inGroup(session.group),
  )
}

export async function restartSession(
  session: SessionAddress,
  input: SessionRestartInput,
): Promise<SessionRestartOutput> {
  await requireAISharing()
  return post(
    `/v1/session/${session.id}/restart`,
    input,
    inGroup(session.group),
  )
}
