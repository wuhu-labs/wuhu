import { useEffect, useState } from 'react'
import { Icon } from '@wuhu/ui'
import { formatSize } from '~/lib/attachments'
import type { DraftFile } from '~/lib/drafts'

function Thumbnail({ file }: { file: File }) {
  const [url, setUrl] = useState<string | null>(null)
  useEffect(() => {
    const created = URL.createObjectURL(file)
    setUrl(created)
    return () => URL.revokeObjectURL(created)
  }, [file])
  return url && <img src={url} alt={file.name} />
}

export function PendingFiles({
  files,
  onRemove,
}: {
  files: readonly DraftFile[]
  onRemove: (id: string) => void
}) {
  if (files.length === 0) return null
  return (
    <ul className='wuhu-pending' aria-label='Files to send'>
      {files.map(({ id, file }) => (
        <li
          key={id}
          className={['image/png', 'image/jpeg'].includes(file.type)
            ? 'wuhu-pending-image'
            : 'wuhu-pending-file'}
        >
          {['image/png', 'image/jpeg'].includes(file.type)
            ? <Thumbnail file={file} />
            : (
              <>
                <Icon name='note' />
                <span>
                  <strong>{file.name}</strong>
                  <span>{formatSize(file.size)}</span>
                </span>
              </>
            )}
          <button
            type='button'
            className='wuhu-pending-remove'
            aria-label={`Remove ${file.name}`}
            onClick={() => onRemove(id)}
          >
            <Icon name='xmark' />
          </button>
        </li>
      ))}
    </ul>
  )
}
