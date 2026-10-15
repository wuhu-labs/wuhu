import { type DeviceKey, generateDeviceKey, mintAssertion } from './assertion'
import type { EnrollConsumeInput, ServerInfo } from '~/lib/contract.gen'
import { objectStore } from './idb'
import { forgetViewer } from './open-cache'

export interface EnrolledDevice extends DeviceKey {
  spaceId: string
  principal?: string
}

const recordKey = 'device'
const withStore = objectStore('wuhu-auth', 'device')

let devicePromise: Promise<EnrolledDevice | null> | null = null
// `clock` is the reading the assertion's times were signed by.
let minted: { assertion: string; expiresAt: number; clock: number } | null =
  null

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

// The browser's clock can be minutes off the server's, either way; every
// assertion time is the server's, read through this offset.
let clockOffsetMs = 0
let clockAsked = false
// Counts the readings that landed; an assertion signed under an older count
// has been superseded by a newer offset.
let clockReadings = 0
let clockReading: Promise<void> | null = null
const clockReadingTimeoutMs = 5_000

function serverSeconds(): number {
  return (Date.now() + clockOffsetMs) / 1000
}

// One reading at a time, given up after a few seconds. A failed or stuck one
// keeps the last offset: signing goes on, and the next refusal reads again.
function readServerClock(): Promise<void> {
  if (clockReading != null) return clockReading
  const controller = new AbortController()
  let timer: ReturnType<typeof setTimeout> | undefined
  clockReading = Promise.race([
    (async () => {
      const response = await fetch('/v1/server', {
        cache: 'no-store',
        signal: controller.signal,
      })
      // Stamped on arrival, after the server read its clock: the estimate
      // errs early, which keeps nbf in the past and only shortens reuse.
      const arrived = Date.now()
      const { now } = (await response.json()) as ServerInfo
      if (typeof now !== 'number' || controller.signal.aborted) return
      clockOffsetMs = now * 1000 - arrived
      clockReadings++
    })(),
    new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        controller.abort()
        reject(new Error('server clock reading timed out'))
      }, clockReadingTimeoutMs)
    }),
  ]).catch(() => undefined).finally(() => {
    clearTimeout(timer)
    clockReading = null
  })
  return clockReading
}

// The server refused an assertion for its times; `clock` is the reading it
// was signed by. A refusal under the latest reading drops what that reading
// signed and reads again; one under a reading since superseded only waits
// for a reading in flight, so a burst costs one.
export function recoverFromClockRefusal(clock: number | null): Promise<void> {
  if (clock === clockReadings) {
    minted = null
    return readServerClock()
  }
  return clockReading ?? Promise.resolve()
}

// The next reading starts from nothing, as on a cold load.
export function forgetServerClock(): void {
  clockOffsetMs = 0
  clockAsked = false
  minted = null
}

export interface SignedAssertion {
  assertion: string
  clock: number
}

export async function signedAssertion(): Promise<SignedAssertion | null> {
  const device = await enrolledDevice()
  if (device == null) return null
  if (!clockAsked) {
    clockAsked = true
    await readServerClock()
  } else if (clockReading != null) {
    await clockReading
  }
  const now = serverSeconds()
  let signed = minted
  if (
    signed == null || signed.clock !== clockReadings ||
    signed.expiresAt - now < renewMarginSeconds
  ) {
    const clock = clockReadings
    const expiresAt = Math.floor(now) + assertionLifetimeSeconds
    signed = {
      assertion: await mintAssertion(device, device.spaceId, now, expiresAt),
      expiresAt,
      clock,
    }
    minted = signed
  }
  return { assertion: signed.assertion, clock: signed.clock }
}

export async function currentAssertion(): Promise<string | null> {
  return (await signedAssertion())?.assertion ?? null
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
