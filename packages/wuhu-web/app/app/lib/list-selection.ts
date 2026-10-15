// A highlighted row that belongs to the list it was chosen in. A new list
// reads as its first row, with nothing to reset. The comparison is identity:
// TipTap passes a new items array per query, so the highlight resets exactly
// when the query changes.
export interface HeldSelection<T> {
  items: readonly T[]
  index: number
}

export function selectionIn<T>(
  held: HeldSelection<T> | null,
  items: readonly T[],
): number {
  return held != null && held.items === items ? held.index : 0
}

// Applies `change` to the row as `items` reads it.
export function holdSelection<T>(
  held: HeldSelection<T> | null,
  items: readonly T[],
  change: (index: number) => number,
): HeldSelection<T> {
  return { items, index: change(selectionIn(held, items)) }
}
