import { ApiError } from '~/sdk/errors'
import { attachmentURL } from './attachments.ts'
import type { ReadOutput } from './contract.gen.ts'

export type FileOpening = 'image' | 'file' | 'text'

export type OpenedFile =
  | { state: 'loading' }
  | { state: 'image'; path: string; size?: number; src: string }
  | { state: 'file'; path: string; size?: number; src: string | null }
  | { state: 'markdown'; content: string; path: string; token: string }
  | { state: 'text'; content: string }

const images = new Set(['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic'])

const binaries = new Set([
  ...['zip', 'gz', 'tgz', 'tar', 'bz2', 'xz', 'zst', '7z', 'rar', 'dmg'],
  ...['pkg', 'ipa', 'apk', 'jar', 'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt'],
  ...['pptx', 'mp3', 'm4a', 'wav', 'aac', 'flac', 'ogg', 'mp4', 'mov', 'm4v'],
  ...['webm', 'mkv', 'avi', 'bmp', 'tif', 'tiff', 'ico', 'psd', 'avif'],
  ...['heif', 'ttf', 'otf', 'woff', 'woff2', 'exe', 'dll', 'so', 'dylib'],
  ...['o', 'a', 'bin', 'wasm', 'class', 'sqlite', 'db'],
])

function extension(path: string): string {
  const name = path.slice(path.lastIndexOf('/') + 1)
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : ''
}

// An extension this does not know opens as text; openFile turns it into a
// file card if the bytes are not UTF-8.
export function fileOpening(path: string): FileOpening {
  const ext = extension(path)
  if (images.has(ext)) return 'image'
  if (binaries.has(ext)) return 'file'
  return 'text'
}

export function fileKind(path: string): string {
  const ext = extension(path)
  return ext === '' ? 'File' : `${ext.toUpperCase()} file`
}

// `origin` names the group's content origin: undefined while its read cookie
// is minted, null for a serve without one. Only images and cards ask for it.
export async function openFile(
  path: string,
  size: number | undefined,
  origin: () => string | null | undefined,
  read: (path: string) => Promise<ReadOutput>,
): Promise<OpenedFile> {
  const bytes = (opening: 'image' | 'file'): OpenedFile => {
    const resolved = origin()
    if (resolved === undefined) return { state: 'loading' }
    const src = resolved === null ? null : attachmentURL(resolved, path)
    if (opening === 'image' && src !== null) {
      return { state: 'image', path, size, src }
    }
    return { state: 'file', path, size, src }
  }
  const opening = fileOpening(path)
  if (opening !== 'text') return bytes(opening)
  let output: ReadOutput
  try {
    output = await read(path)
  } catch (failure) {
    if (failure instanceof ApiError && failure.code === 'unsupported') {
      return bytes('file')
    }
    throw failure
  }
  const { content, token } = output
  if (content.includes('\u0000')) return bytes('file')
  if (path.endsWith('.md') || path.endsWith('.markdown')) {
    return { state: 'markdown', content, path, token }
  }
  return { state: 'text', content }
}
