import type { SpaceClient } from '~/sdk/client'
import type { EntryKind, ListOutput, MutationEvent } from './contract.gen'

export type PathMap = Map<string, EntryKind>

export interface TreeNode {
  name: string
  path: string
  kind: EntryKind
  children: TreeNode[]
}

export async function loadPaths(
  client: SpaceClient,
): Promise<{ paths: PathMap; rev: number }> {
  const paths: PathMap = new Map()
  const root = await client.ls('/')
  const queue: [string, ListOutput][] = [['/', root]]
  while (queue.length > 0) {
    const [dir, output] = queue.shift()!
    for (const entry of output.entries) {
      const path = dir === '/' ? `/${entry.name}` : `${dir}/${entry.name}`
      paths.set(path, entry.kind)
      if (entry.kind === 'directory') queue.push([path, await client.ls(path)])
    }
  }
  return { paths, rev: root.rev ?? 0 }
}

export function ancestorPaths(path: string): string[] {
  const segments = path.split('/').filter(Boolean)
  return segments.slice(0, -1).map((_, index) =>
    `/${segments.slice(0, index + 1).join('/')}`
  )
}

export function applyEvent(paths: PathMap, event: MutationEvent): PathMap {
  const next = new Map(paths)
  switch (event.kind) {
    case 'write':
      next.set(event.path, event.entry)
      break
    case 'delete':
      removeSubtree(next, event.path)
      break
    case 'move': {
      const moved = collectSubtree(next, event.path)
      removeSubtree(next, event.path)
      for (const [path, kind] of moved) {
        next.set(event.to + path.slice(event.path.length), kind)
      }
      break
    }
  }
  return next
}

export function buildTree(paths: PathMap): TreeNode[] {
  const roots: TreeNode[] = []
  const byPath = new Map<string, TreeNode>()
  const nodeFor = (path: string, kind: EntryKind): TreeNode => {
    const existing = byPath.get(path)
    if (existing) {
      if (kind !== 'directory') existing.kind = kind
      return existing
    }
    const node: TreeNode = {
      name: path.slice(path.lastIndexOf('/') + 1),
      path,
      kind,
      children: [],
    }
    byPath.set(path, node)
    const parentEnd = path.lastIndexOf('/')
    if (parentEnd === 0) {
      roots.push(node)
    } else {
      nodeFor(path.slice(0, parentEnd), 'directory').children.push(node)
    }
    return node
  }
  for (const [path, kind] of paths) nodeFor(path, kind)
  const sort = (nodes: TreeNode[]) => {
    for (const node of nodes) {
      if (node.children.length > 0) node.kind = 'directory'
    }
    nodes.sort((a, b) => {
      const aDir = a.kind === 'directory' ? 0 : 1
      const bDir = b.kind === 'directory' ? 0 : 1
      return aDir - bDir || a.name.localeCompare(b.name)
    })
    for (const node of nodes) sort(node.children)
  }
  sort(roots)
  return roots
}

function collectSubtree(paths: PathMap, root: string): [string, EntryKind][] {
  const collected: [string, EntryKind][] = []
  for (const [path, kind] of paths) {
    if (path === root || path.startsWith(`${root}/`)) {
      collected.push([path, kind])
    }
  }
  return collected
}

function removeSubtree(paths: PathMap, root: string) {
  for (const path of [...paths.keys()]) {
    if (path === root || path.startsWith(`${root}/`)) {
      paths.delete(path)
    }
  }
}
