import { useState } from 'react'
import { Icon } from '@wuhu/ui'
import { attachmentName, formatSize } from '~/lib/attachments'
import { fileKind } from '~/lib/file-opening'
import { crossOriginFor } from '~/lib/groups'

type Attempt = 'first' | 'reminting' | 'retry' | 'failed'

export function FileImage({
  group,
  path,
  size,
  src,
  remint,
}: {
  group: string
  path: string
  size?: number
  src: string
  // A refused read cookie fails the load like an undecodable image does.
  remint: () => Promise<unknown>
}) {
  const [attempt, setAttempt] = useState<Attempt>('first')
  const failed = () => {
    if (attempt !== 'first') return setAttempt('failed')
    setAttempt('reminting')
    remint().then(() => setAttempt('retry'), () => setAttempt('failed'))
  }
  if (attempt === 'failed') {
    return <FileCard path={path} size={size} src={src} />
  }
  if (attempt === 'reminting') return null
  return (
    <img
      key={attempt}
      className='wuhu-file-image'
      src={src}
      crossOrigin={crossOriginFor(group)}
      alt={attachmentName(path)}
      onError={failed}
    />
  )
}

export function FileCard({
  path,
  size,
  src,
}: {
  path: string
  size?: number
  src: string | null
}) {
  const detail = size == null
    ? fileKind(path)
    : `${fileKind(path)} · ${formatSize(size)}`
  return (
    <div className='wuhu-attachment-file wuhu-file-card'>
      <Icon name='note' />
      <span>
        <strong>{attachmentName(path)}</strong>
        <span>{detail}</span>
      </span>
      {src != null && (
        <a className='wuhu-button-secondary' href={`${src}?download=1`}>
          Download
        </a>
      )}
    </div>
  )
}
