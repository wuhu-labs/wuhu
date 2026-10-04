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

export const zeroInsets: ShellInsets = { top: 0, left: 0, right: 0, bottom: 0 }

export function totalInsets(
  safeArea: ShellInsets,
  chrome: ShellInsets,
): ShellInsets {
  return {
    top: safeArea.top + chrome.top,
    left: safeArea.left + chrome.left,
    right: safeArea.right + chrome.right,
    bottom: safeArea.bottom + chrome.bottom,
  }
}

export function deviceSafeArea(): ShellInsets {
  const probe = document.createElement('div')
  probe.style.cssText =
    'position:fixed;visibility:hidden;pointer-events:none;padding:env(safe-area-inset-top,0px) env(safe-area-inset-right,0px) env(safe-area-inset-bottom,0px) env(safe-area-inset-left,0px)'
  document.body.append(probe)
  const style = getComputedStyle(probe)
  const insets = {
    top: Number.parseFloat(style.paddingTop) || 0,
    left: Number.parseFloat(style.paddingLeft) || 0,
    right: Number.parseFloat(style.paddingRight) || 0,
    bottom: Number.parseFloat(style.paddingBottom) || 0,
  }
  probe.remove()
  return insets
}
