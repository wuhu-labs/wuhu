import type { Insets } from '@wuhu/ui'

export type ContentMessage =
  | { type: 'wuhu:ready' }
  | { type: 'wuhu:unauthorized' }
  | { type: 'wuhu:navigate'; path: string }

export interface ShellContextMessage {
  type: 'wuhu:context'
  mode: 'shell'
  access: 'member'
  shellOrigin: string
  insets: Insets
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
  insets: Insets,
): ShellContextMessage {
  return {
    type: 'wuhu:context',
    mode: 'shell',
    access: 'member',
    shellOrigin,
    insets,
  }
}
