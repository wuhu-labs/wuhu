export interface AttachmentView {
  kind: 'image' | 'file'
  path: string
  mimeType: string
  size?: number | null
}

export type AttachmentDisplay = 'image' | 'video' | 'file'

export function attachmentDisplay(
  attachment: AttachmentView,
  canPlay: (mimeType: string) => boolean,
): AttachmentDisplay {
  if (attachmentIsActiveDocument(attachment)) return 'file'
  if (attachment.kind === 'image') return 'image'
  if (
    attachment.mimeType.startsWith('video/') && canPlay(attachment.mimeType)
  ) {
    return 'video'
  }
  return 'file'
}

export function attachmentIsActiveDocument(
  attachment: AttachmentView,
): boolean {
  return /\.(?:html?|xhtml|xht|svg|xml)$/i.test(attachment.path) ||
    [
      'text/html',
      'application/xhtml+xml',
      'image/svg+xml',
      'application/xml',
      'text/xml',
    ].includes(attachment.mimeType)
}

export function attachmentName(path: string): string {
  return path.split('/').filter((part) => part !== '').pop() ?? path
}

// A path is hostless in the conversation's group and
// wuhu://<group>.localspace/<path> to a reader acting elsewhere. Either way the
// file opens at its hostless path on the viewer's own content origin, which
// serves a conversation's attachment folder to its members and to readers of
// its group, whichever group homes it.
const groupHost = /^wuhu:\/\/[^/]*\.localspace(?=\/)/i

export function attachmentURL(origin: string, path: string): string {
  return origin +
    path.replace(groupHost, '').split('/').map(encodeURIComponent).join('/')
}

const units = ['KB', 'MB', 'GB']

export function formatSize(bytes: number): string {
  if (bytes < 1000) return `${bytes} bytes`
  let value = bytes / 1000
  let unit = 0
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000
    unit += 1
  }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`
}

export function attachmentDetail(attachment: AttachmentView): string {
  const type = attachment.mimeType
  return attachment.size == null
    ? type
    : `${type} · ${formatSize(attachment.size)}`
}
