export type NewDocumentPath =
  | { path: string }
  | { error: string }

export function newDocumentPath(
  directory: string,
  name: string,
  exists: (path: string) => boolean,
): NewDocumentPath {
  const trimmed = name.trim()
  if (trimmed === '') return { error: 'Name a document to create it.' }
  if (trimmed.includes('/')) {
    return { error: 'A document name cannot contain "/".' }
  }
  if (trimmed === '.' || trimmed === '..') {
    return { error: `"${trimmed}" is not a document name.` }
  }
  const file = trimmed.includes('.') ? trimmed : `${trimmed}.md`
  const path = directory === '/' ? `/${file}` : `${directory}/${file}`
  if (exists(path)) return { error: `${path} already exists.` }
  return { path }
}
