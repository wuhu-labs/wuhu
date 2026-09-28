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
  if (attachment.kind === 'image') return 'image'
  if (
    attachment.mimeType.startsWith('video/') && canPlay(attachment.mimeType)
  ) {
    return 'video'
  }
  return 'file'
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

const MiB = 1024 * 1024

export const attachmentLimits = {
  files: 8,
  fileBytes: 50 * MiB,
  totalBytes: 150 * MiB,
}

type Sized = Pick<File, 'name' | 'size'>

function names(files: readonly Sized[]): string {
  return files.map((file) => file.name).join(', ')
}

// Takes what fits under `attachmentLimits`, in order, and says what it left out.
export function admitFiles<F extends Sized>(
  held: readonly Sized[],
  incoming: readonly F[],
): { admitted: F[]; refusal: string | null } {
  let count = held.length
  let total = held.reduce((sum, file) => sum + file.size, 0)
  const admitted: F[] = []
  const tooMany: F[] = []
  const tooLarge: F[] = []
  const overTotal: F[] = []
  for (const file of incoming) {
    if (file.size > attachmentLimits.fileBytes) tooLarge.push(file)
    else if (count >= attachmentLimits.files) tooMany.push(file)
    else if (total + file.size > attachmentLimits.totalBytes) {
      overTotal.push(file)
    } else {
      admitted.push(file)
      count += 1
      total += file.size
    }
  }
  const reasons = [
    tooLarge.length > 0 &&
    `${names(tooLarge)}: a file can be at most ${
      attachmentLimits.fileBytes / MiB
    } MiB.`,
    overTotal.length > 0 &&
    `${names(overTotal)}: a message can carry at most ${
      attachmentLimits.totalBytes / MiB
    } MiB in all.`,
    tooMany.length > 0 &&
    `${
      names(tooMany)
    }: a message can carry at most ${attachmentLimits.files} files.`,
  ].filter((reason) => reason !== false)
  return {
    admitted,
    refusal: reasons.length === 0 ? null : `Not attached. ${reasons.join(' ')}`,
  }
}
