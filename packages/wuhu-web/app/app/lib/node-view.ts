import { ApiError } from '~/sdk/errors'
import type { EntryKind, ReadOutput } from './contract.gen.ts'
import { type OpenedFile, openFile } from './file-opening.ts'
import type { ContentOrigin } from './use-content-origin.ts'
import { viewOpening } from './view-opening.ts'

export type NodeView =
  | Exclude<OpenedFile, { state: 'text' }>
  | { state: 'error'; message: string }
  | { state: 'text'; content: string; notice?: string }
  | { state: 'html'; origin: string; src: string }
  | { state: 'table'; path: string }

interface NodeEntry {
  kind: EntryKind
  size?: number
}

// A stat rejects with notFound for a path that is not there; any other
// failure is not an answer.
export interface NodeSource {
  stat(path: string): Promise<NodeEntry>
  read(path: string): Promise<ReadOutput>
}

// The root opens its index.html, else its index.md, else its listing: the
// lookup a group host makes for a folder, with the Markdown in the viewer.
export const homepages = ['/index.html', '/index.md']

async function homepage(
  source: NodeSource,
): Promise<{ path: string; entry: NodeEntry }> {
  for (const path of homepages) {
    const entry = await source.stat(path).catch((failure: unknown) => {
      if (failure instanceof ApiError && failure.code === 'notFound') return
      throw failure
    })
    if (entry) return { path, entry }
  }
  return { path: '/', entry: { kind: 'directory' } }
}

export async function loadNode(
  source: NodeSource,
  contentOrigin: ContentOrigin,
  requested: string,
  suffix: string,
  viewRev: number,
): Promise<NodeView> {
  const { path, entry: { kind, size } } = requested === '/'
    ? await homepage(source)
    : { path: requested, entry: await source.stat(requested) }
  if (kind === 'table') return { state: 'table', path }
  if (kind === 'directory') {
    const origin = resolvedContentOrigin(contentOrigin)
    if (origin === undefined) return { state: 'loading' }
    if (origin != null) {
      const directory = path === '/' ? path : `${path}/`
      return {
        state: 'html',
        origin,
        src: origin + encodeURI(directory) + suffix,
      }
    }
    return { state: 'error', message: 'Server reports no web origin.' }
  }
  if (path.endsWith('.html') || path.endsWith('.htm')) {
    const origin = resolvedContentOrigin(contentOrigin)
    if (origin === undefined) return { state: 'loading' }
    if (origin) {
      return {
        state: 'html',
        origin,
        src: origin + encodeURI(path) + suffix,
      }
    }
    const { content } = await source.read(path)
    return {
      state: 'text',
      content,
      notice: 'Server reports no web origin — showing raw HTML.',
    }
  }
  if (path.endsWith('.view')) {
    const { content } = await source.read(path)
    const opening = viewOpening(content)
    if (opening.state === 'text') return opening
    const doc = opening.doc
    const origin = resolvedContentOrigin(contentOrigin)
    if (origin === undefined) return { state: 'loading' }
    if (!origin) {
      return {
        state: 'text',
        content,
        notice: 'Server reports no web origin — showing the raw view doc.',
      }
    }
    const params = new URLSearchParams({ path, rev: String(viewRev) })
    return {
      state: 'html',
      origin,
      src: `${origin}/_/views/${encodeURIComponent(doc.view)}?${params}`,
    }
  }
  return openFile(
    path,
    size,
    () => resolvedContentOrigin(contentOrigin),
    source.read,
  )
}

function resolvedContentOrigin(
  contentOrigin: ContentOrigin,
): string | null | undefined {
  if (contentOrigin instanceof Error) throw contentOrigin
  return contentOrigin
}
