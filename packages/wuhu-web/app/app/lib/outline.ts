export interface Parented {
  id: string
  parent: string | null
}

export interface Branch<T> {
  item: T
  children: Branch<T>[]
}

export interface OutlineRow<T> {
  item: T
  depth: number
  hasChildren: boolean
  open: boolean
}

// An item whose parent is not in the list is a root, so filtering a parent out
// never hides its descendants. A parent cycle has no root; the walk enters it
// at its first member in list order and cuts it there.
export function nest<T extends Parented>(items: readonly T[]): Branch<T>[] {
  const ids = new Set(items.map((item) => item.id))
  const children = new Map<string, T[]>()
  for (const item of items) {
    if (item.parent == null) continue
    children.set(item.parent, [...children.get(item.parent) ?? [], item])
  }
  const visited = new Set<string>()
  const build = (item: T): Branch<T>[] => {
    if (visited.has(item.id)) return []
    visited.add(item.id)
    return [{
      item,
      children: (children.get(item.id) ?? []).flatMap(build),
    }]
  }
  const roots = items.filter((item) =>
    item.parent == null || !ids.has(item.parent)
  )
  return [...roots, ...items].flatMap(build)
}

export function flatten<T extends Parented>(
  branches: readonly Branch<T>[],
  isOpen: (id: string) => boolean,
  depth = 0,
): OutlineRow<T>[] {
  return branches.flatMap((branch) => {
    const open = isOpen(branch.item.id)
    return [
      {
        item: branch.item,
        depth,
        hasChildren: branch.children.length > 0,
        open,
      },
      ...(open ? flatten(branch.children, isOpen, depth + 1) : []),
    ]
  })
}

export function ancestors<T extends Parented>(
  items: readonly T[],
  id: string,
): string[] {
  const parents = new Map(items.map((item) => [item.id, item.parent]))
  const found: string[] = []
  let cursor = parents.get(id) ?? null
  while (cursor != null && parents.has(cursor) && !found.includes(cursor)) {
    found.push(cursor)
    cursor = parents.get(cursor) ?? null
  }
  return found
}

// Rows keep the place they were first drawn in, so activity reordering the
// roster does not move them under the pointer; newcomers join at the end.
export function stableOrder<T extends { id: string }>(
  items: readonly T[],
  prior: readonly string[],
): T[] {
  const byId = new Map(items.map((item) => [item.id, item]))
  const known = new Set(prior)
  return [
    ...prior.flatMap((id) => byId.get(id) ?? []),
    ...items.filter((item) => !known.has(item.id)),
  ]
}
