import { useSyncExternalStore } from 'react'

// Which Enter chord sends from the composer in this browser. Shift+Enter is
// the default; the other chord adds a line.
export type SendKey = 'shift-enter' | 'enter'

const storageKey = 'wuhu.composer-send-key'
const changedEvent = 'wuhu:composer-send-key'

export function sendKey(): SendKey {
  return localStorage.getItem(storageKey) === 'enter' ? 'enter' : 'shift-enter'
}

export function setSendKey(key: SendKey): void {
  localStorage.setItem(storageKey, key)
  globalThis.dispatchEvent(new Event(changedEvent))
}

// Calls changed when this tab or another one picks a different chord.
export function subscribeSendKey(changed: () => void): () => void {
  const onStorage = (event: StorageEvent) => {
    if (event.key === storageKey) changed()
  }
  globalThis.addEventListener('storage', onStorage)
  globalThis.addEventListener(changedEvent, changed)
  return () => {
    globalThis.removeEventListener('storage', onStorage)
    globalThis.removeEventListener(changedEvent, changed)
  }
}

export function useSendKey(): SendKey {
  return useSyncExternalStore(subscribeSendKey, sendKey, () => 'shift-enter')
}

export function sendKeyLabel(key: SendKey): string {
  return key === 'enter' ? 'Enter' : 'Shift+Enter'
}

// An input method's Return that commits a candidate is not a send. Most
// browsers flag it with isComposing; Safari can end composition first and
// deliver key 'Enter' with only keyCode 229 left to tell.
export function isComposerSendKey({
  isComposing,
  key,
  keyCode,
  shiftKey,
  sendKey,
}: {
  isComposing: boolean
  key: string
  keyCode: number
  shiftKey: boolean
  sendKey: SendKey
}): boolean {
  return key === 'Enter' && shiftKey === (sendKey === 'shift-enter') &&
    !isComposing && keyCode !== 229
}
