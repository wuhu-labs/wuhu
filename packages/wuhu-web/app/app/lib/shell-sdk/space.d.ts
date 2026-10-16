import type { Space } from './space-core.d.ts'

export { SpaceError } from './space-core.d.ts'

export const query: Space['query']
export const observe: Space['observe']
export const watch: Space['watch']
export const mutateRows: Space['mutateRows']
export const readAttributes: Space['readAttributes']
export const patchAttributes: Space['patchAttributes']
export const find: Space['find']
export const grep: Space['grep']

export const fetch: typeof globalThis.fetch
