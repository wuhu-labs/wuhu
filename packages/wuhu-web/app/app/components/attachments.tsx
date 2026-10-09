import { Icon } from '@wuhu/ui'
import {
  attachmentDetail,
  attachmentDisplay,
  attachmentIsActiveDocument,
  attachmentName,
  attachmentURL,
  type AttachmentView,
} from '~/lib/attachments'

function browserCanPlay(mimeType: string): boolean {
  if (typeof document === 'undefined') return false
  return document.createElement('video').canPlayType(mimeType) !== ''
}

export function Attachments({
  attachments,
  origin,
  crossOrigin,
  canPlay = browserCanPlay,
}: {
  attachments: AttachmentView[]
  origin: string | null
  // A group host's reads carry the cookie.
  crossOrigin?: 'use-credentials'
  canPlay?: (mimeType: string) => boolean
}) {
  if (attachments.length === 0) return null
  const shown = attachments.map((attachment) => ({
    attachment,
    display: attachmentDisplay(attachment, canPlay),
    download: attachmentIsActiveDocument(attachment),
    url: origin == null ? null : attachmentURL(origin, attachment.path),
  }))
  const media = shown.filter((item) => item.display !== 'file')
  const files = shown.filter((item) => item.display === 'file')
  return (
    <div className='wuhu-attachments'>
      {media.length > 0 && (
        <div className='wuhu-attachment-media'>
          {media.map(({ attachment, display, url }) =>
            display === 'video'
              ? (
                <video
                  key={attachment.path}
                  className='wuhu-attachment-tile'
                  src={url ?? undefined}
                  crossOrigin={crossOrigin}
                  controls
                  playsInline
                  preload='metadata'
                  aria-label={attachmentName(attachment.path)}
                />
              )
              : (
                <a
                  key={attachment.path}
                  className='wuhu-attachment-tile'
                  href={url ?? undefined}
                  target='_blank'
                  rel='noreferrer'
                >
                  {url != null && (
                    <img
                      src={url}
                      crossOrigin={crossOrigin}
                      alt={attachmentName(attachment.path)}
                      loading='lazy'
                    />
                  )}
                </a>
              )
          )}
        </div>
      )}
      {files.map(({ attachment, url, download }) => (
        <a
          key={attachment.path}
          className='wuhu-attachment-file'
          href={url == null ? undefined : url + (download ? '?download=1' : '')}
          download={download ? attachmentName(attachment.path) : undefined}
          target={download ? undefined : '_blank'}
          rel={download ? undefined : 'noreferrer'}
        >
          <Icon name='note' />
          <span>
            <strong>{attachmentName(attachment.path)}</strong>
            <span>{attachmentDetail(attachment)}</span>
          </span>
        </a>
      ))}
    </div>
  )
}
