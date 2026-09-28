export function isComposerSendKey({
  isComposing,
  key,
  shiftKey,
}: {
  isComposing: boolean
  key: string
  shiftKey: boolean
}): boolean {
  return key === 'Enter' && shiftKey && !isComposing
}
