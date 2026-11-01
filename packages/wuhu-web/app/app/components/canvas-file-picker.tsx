import { useEffect, useState } from 'react'
import { errorMessage } from '~/sdk/errors'
import { ModalDialog } from './modal-dialog'

// A space path for a file card: typed in full, or picked from the files
// whose path holds what is typed.

const resultLimit = 50

export function globFor(query: string): string {
  const term = query.trim().replace(/^\/+/, '')
  return term === '' ? '**/*' : `**/*${term}*`
}

export function FilePicker({ open, find, onPick, onClose }: {
  open: boolean
  find(glob: string, limit: number): Promise<string[]>
  onPick(path: string): void
  onClose(): void
}) {
  const [query, setQuery] = useState('')
  const [paths, setPaths] = useState<string[]>([])
  const [failure, setFailure] = useState<string | null>(null)

  useEffect(() => {
    if (!open) return
    let live = true
    const timer = setTimeout(() => {
      find(globFor(query), resultLimit).then((found) => {
        if (!live) return
        setPaths(found)
        setFailure(null)
      }, (error: unknown) => {
        if (live) setFailure(errorMessage(error))
      })
    }, 150)
    return () => {
      live = false
      clearTimeout(timer)
    }
  }, [open, query])

  const typed = query.trim()
  return (
    <ModalDialog open={open} title='Add a file' onClose={onClose}>
      <div className='wuhu-form'>
        <label className='wuhu-field wuhu-field-wide'>
          <span>path</span>
          <input
            autoFocus
            placeholder='Search, or type a path from /'
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key !== 'Enter') return
              if (typed.startsWith('/')) onPick(typed)
              else if (paths.length > 0) onPick(paths[0])
            }}
          />
        </label>
        {failure && <p className='wuhu-alert'>{failure}</p>}
        <ul className='canvas-file-list' aria-label='Files'>
          {paths.map((path) => (
            <li key={path}>
              <button type='button' onClick={() => onPick(path)}>{path}</button>
            </li>
          ))}
        </ul>
        <div className='wuhu-form-actions'>
          <button type='button' className='wuhu-quiet-button' onClick={onClose}>
            Cancel
          </button>
        </div>
      </div>
    </ModalDialog>
  )
}
