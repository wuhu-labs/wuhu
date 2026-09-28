import { ApiError } from '~/sdk/errors'

export interface ChainSplit {
  ancestors: string[]
  own: string
}

export interface Preview {
  text: string
  truncated: boolean
}

export const previewLineCount = 6

export function ownBriefPath(home: string): string {
  return `${home}/AGENTS.md`
}

// The server lists a chain path only when the file resolved, so the session's
// own brief is absent from `chain` until it exists — it is the editable slot
// either way.
export function splitChain(chain: string[], home: string): ChainSplit {
  const own = ownBriefPath(home)
  return { ancestors: chain.filter((path) => path !== own), own }
}

export function previewLines(
  content: string,
  limit = previewLineCount,
): Preview {
  const lines = content.split('\n')
  if (lines.slice(limit).every((line) => line.trim() === '')) {
    return { text: content, truncated: false }
  }
  return { text: lines.slice(0, limit).join('\n'), truncated: true }
}

export function isNotFound(failure: unknown): boolean {
  return failure instanceof ApiError &&
    (failure.status === 404 || failure.code === 'notFound')
}

export function sizeLabel(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}
