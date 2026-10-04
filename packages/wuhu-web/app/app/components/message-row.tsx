import { Attachments } from '~/components/attachments'
import { Avatar } from '~/components/avatar'
import { Markdown } from '~/components/markdown-view'
import { CopyButton } from '~/components/copy-button'
import {
  type MessageMap,
  quoteExcerpt,
  quoteFor,
  type ReplyDraft,
  replyDraft,
} from '~/lib/conversation'
import { senderIsSession, senderName } from '~/lib/directory'
import { kindTag, wakeTime } from '~/lib/turn-labels'
import { crossOriginFor, senderGroupLabel } from '~/lib/groups'
import {
  useDirectory,
  useGroupOrigin,
  useSessionTitles,
} from '~/lib/use-directory'
import type { ConversationMessagePayload } from '~/lib/contract.gen'

function shortId(id: string) {
  return id.slice(0, 8)
}

export function QuoteStrip({
  sender,
  text,
  onClear,
}: {
  sender: string
  text: string
  onClear?: () => void
}) {
  return (
    <div className='wuhu-quote'>
      <span className='wuhu-quote-sender'>{sender}</span>
      <span className='wuhu-quote-text'>{quoteExcerpt(text)}</span>
      {onClear && (
        <button
          type='button'
          className='wuhu-quote-clear'
          aria-label='Clear reply target'
          onClick={onClear}
        >
          ×
        </button>
      )}
    </div>
  )
}

export function MessageRow({
  message,
  messages,
  group,
  own,
  onReply,
}: {
  message: ConversationMessagePayload
  messages: MessageMap
  group: string
  own: boolean
  onReply?: (draft: ReplyDraft) => void
}) {
  const directory = useDirectory()
  const origin = useGroupOrigin(group)
  const sessions = useSessionTitles()
  const sender = senderName(directory, message, sessions)
  const fromSession = senderIsSession(sessions, message)
  const quote = quoteFor(messages, message)
  const sent = new Date(message.createdAt * 1000)
  const tag = kindTag(message.kind)
  const senderGroup = senderGroupLabel(message.senderGroup, group, directory)
  return (
    <div
      id={`msg-${message.messageId}`}
      className='wuhu-message'
      data-history-id={message.messageId}
      data-own={own || undefined}
    >
      <div className='wuhu-entry-head'>
        {!own && (
          <>
            <Avatar
              principal={message.sender}
              name={fromSession ? sender : undefined}
              session={fromSession}
              size={28}
            />
            <strong title={message.sender}>{sender}</strong>
            {senderGroup !== null && (
              <span className='wuhu-sender-group'>{senderGroup}</span>
            )}
          </>
        )}
        {tag !== null && (
          <span className='wuhu-turn-tag' data-tone={tag.tone}>{tag.tag}</span>
        )}
        <time
          dateTime={sent.toISOString()}
          title={`${sent.toLocaleString()} · ${message.senderTimezone}`}
        >
          {wakeTime(sent, new Date())}
        </time>
        <span className='wuhu-id' title={message.messageId}>
          {shortId(message.messageId)}
        </span>
        <span className='wuhu-message-actions'>
          {onReply && (
            <button
              type='button'
              className='wuhu-quiet-button'
              onClick={() => onReply(replyDraft(message))}
            >
              Reply
            </button>
          )}
          <CopyButton text={message.text} />
        </span>
      </div>
      <div className='wuhu-bubble'>
        {quote.kind === 'quote' && (
          <a
            className='wuhu-quote-link'
            href={`#msg-${quote.message.messageId}`}
          >
            <QuoteStrip
              sender={senderName(directory, quote.message, sessions)}
              text={quote.message.text}
            />
          </a>
        )}
        {quote.kind === 'missing' && (
          <div
            className='wuhu-quote wuhu-quote-missing'
            title={quote.messageId}
          >
            replying to an earlier message
          </div>
        )}
        <Attachments
          attachments={message.attachments ?? []}
          origin={origin}
          crossOrigin={crossOriginFor(group)}
        />
        <article className='wuhu-markdown'>
          <Markdown>{message.text}</Markdown>
        </article>
      </div>
    </div>
  )
}
