import { type DeviceKey, generateDeviceKey, mintAssertion } from './assertion'
import type { EnrollConsumeInput } from '~/lib/contract.gen'
import { objectStore } from './idb'
import { forgetViewer } from './open-cache'

export interface EnrolledDevice extends DeviceKey {
  spaceId: string
  principal?: string
}

const recordKey = 'device'
const withStore = objectStore('wuhu-auth', 'device')

let devicePromise: Promise<EnrolledDevice | null> | null = null
let minted: { assertion: string; expiresAt: number } | null = null

async function readDevice(): Promise<EnrolledDevice | null> {
  const stored = await withStore('readonly', (store) => store.get(recordKey))
  return (stored as EnrolledDevice | undefined) ?? null
}

// Only a resolved read is memoized: a flaky indexedDB.open must not brand an
// enrolled user "unenrolled" forever — the next call retries.
export function enrolledDevice(): Promise<EnrolledDevice | null> {
  if (devicePromise == null) {
    const pending = readDevice()
    devicePromise = pending
    pending.catch(() => {
      if (devicePromise === pending) devicePromise = null
    })
  }
  return devicePromise
}

const assertionLifetimeSeconds = 300
const renewMarginSeconds = 60

export async function currentAssertion(): Promise<string | null> {
  const device = await enrolledDevice()
  if (device == null) return null
  const now = Date.now() / 1000
  if (minted == null || minted.expiresAt - now < renewMarginSeconds) {
    const expiresAt = Math.floor(now) + assertionLifetimeSeconds
    minted = {
      assertion: await mintAssertion(device, device.spaceId, expiresAt),
      expiresAt,
    }
  }
  return minted.assertion
}

export async function authHeaders(): Promise<Record<string, string>> {
  const assertion = await currentAssertion()
  return assertion == null ? {} : { authorization: `Bearer ${assertion}` }
}

async function errorMessage(response: Response): Promise<string> {
  const text = await response.text()
  try {
    return (JSON.parse(text) as { message: string }).message
  } catch {
    return `HTTP ${response.status}`
  }
}

export async function enroll(
  token: string,
  space: string,
): Promise<void> {
  const key = await generateDeviceKey()
  // Persist the key before burning the one-time token: a storage failure then
  // leaves the invite intact for a retry instead of consuming it into nothing.
  await withStore(
    'readwrite',
    (store) =>
      store.put({ ...key, spaceId: space } satisfies EnrolledDevice, recordKey),
  )
  devicePromise = null
  minted = null
  const input: EnrollConsumeInput = { token, pubkey: key.label }
  let response: Response
  try {
    response = await fetch('/v1/enroll/consume', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(input),
    })
  } catch (failure) {
    await discardDevice()
    throw failure
  }
  if (!response.ok) {
    await discardDevice()
    throw new Error(await errorMessage(response))
  }
}

export async function recordPrincipal(principal: string): Promise<void> {
  const device = await enrolledDevice()
  if (device == null || device.principal === principal) return
  const updated: EnrolledDevice = { ...device, principal }
  await withStore('readwrite', (store) => store.put(updated, recordKey))
  devicePromise = Promise.resolve(updated)
}

async function discardDevice(): Promise<void> {
  await withStore('readwrite', (store) => store.delete(recordKey)).catch(
    () => undefined,
  )
  devicePromise = null
  minted = null
}

export async function logout(contentOrigin: string | null): Promise<void> {
  if (contentOrigin != null) {
    await fetch(`${contentOrigin}/_/session`, {
      method: 'DELETE',
      credentials: 'include',
    }).catch(() => undefined)
  }
  await import('./web-push')
    .then(({ removeWebPushSubscription }) => removeWebPushSubscription())
    .catch(() => undefined)
  // Self-revocation is best-effort and must never gate the local wipe: if
  // minting the bearer throws (a drifted record), the delete below still runs.
  try {
    const headers = await authHeaders()
    if (headers.authorization != null) {
      await fetch('/v1/key', { method: 'DELETE', headers }).catch(
        () => undefined,
      )
    }
  } catch {
    // fall through to the unconditional local wipe
  }
  // What this account saw never paints for the next one.
  await enrolledDevice().then(forgetViewer).catch(() => undefined)
  await discardDevice()
}
