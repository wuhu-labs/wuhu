export interface ShellInsets {
  top: number
  left: number
  right: number
  bottom: number
}

export type ContentMessage =
  | { type: 'wuhu:ready' }
  | { type: 'wuhu:unauthorized' }
  | { type: 'wuhu:navigate'; path: string }

export interface ShellContextMessage {
  type: 'wuhu:context'
  mode: 'shell'
  access: 'member'
  shellOrigin: string
  insets: ShellInsets
}

// deno-lint-ignore no-control-regex
const invalidPath = /[\u0000-\u001f\u007f]/

export function contentMessage(value: unknown): ContentMessage | null {
  if (value == null || typeof value !== 'object' || Array.isArray(value)) {
    return null
  }
  const record = value as Record<string, unknown>
  if (record.type === 'wuhu:ready' || record.type === 'wuhu:unauthorized') {
    return Object.keys(record).length === 1 ? { type: record.type } : null
  }
  if (
    record.type !== 'wuhu:navigate' ||
    Object.keys(record).length !== 2 ||
    typeof record.path !== 'string' ||
    !record.path.startsWith('/') ||
    record.path.startsWith('//') ||
    record.path.split('/').includes('..') ||
    invalidPath.test(record.path)
  ) {
    return null
  }
  return { type: 'wuhu:navigate', path: record.path }
}

export function shellContext(
  shellOrigin: string,
  insets: ShellInsets,
): ShellContextMessage {
  return {
    type: 'wuhu:context',
    mode: 'shell',
    access: 'member',
    shellOrigin,
    insets,
  }
}

export const chromeGeometry = { sidebarWidth: 256 } as const

// An inset is the obstruction this shell adds on top of the platform's own safe
// area, which the SDK already composes in. The sidebar is real layout now, not
// floating chrome, so an embedded page sits under nothing and the residue is
// zero.
export const zeroInsets: ShellInsets = { top: 0, left: 0, right: 0, bottom: 0 }
