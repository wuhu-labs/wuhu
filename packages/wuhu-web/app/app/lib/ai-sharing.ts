export type AISharing = 'allowed' | 'declined'

// localStorage belongs to the origin, and an origin serves one space, so one
// key is one space in this browser, enrolled or not.
const storageKey = 'wuhu.ai-sharing'

export function aiSharing(): AISharing | null {
  const stored = localStorage.getItem(storageKey)
  return stored === 'allowed' || stored === 'declined' ? stored : null
}

export function decideAISharing(decision: AISharing): void {
  localStorage.setItem(storageKey, decision)
}

export const aiSharingRefusal =
  'AI sharing is off for this space. Open Settings → AI sharing to review and allow it.'

// Read at every call, so a choice made in another tab applies here at once.
export function requireAISharing(): Promise<void> {
  return aiSharing() === 'allowed'
    ? Promise.resolve()
    : Promise.reject(new Error(aiSharingRefusal))
}
