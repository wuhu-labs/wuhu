import type {
  WebPushConfigOutput,
  WebPushSubscriptionDeleteInput,
  WebPushSubscriptionInput,
} from '~/lib/contract.gen'
import { api, authorizedRequest } from './http'
import { registerServiceWorker } from './service-worker'

export type WebPushState =
  | { kind: 'unsupported' }
  | { kind: 'install-required' }
  | { kind: 'blocked' }
  | { kind: 'disabled' }
  | { kind: 'enabled' }
  | { kind: 'working' }
  | { kind: 'error'; message: string }

export function webPushAvailability(): WebPushState | null {
  if (
    !globalThis.isSecureContext ||
    !('serviceWorker' in navigator) ||
    !('PushManager' in globalThis) ||
    !('Notification' in globalThis)
  ) return { kind: 'unsupported' }
  const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
  if (ios && !globalThis.matchMedia('(display-mode: standalone)').matches) {
    return { kind: 'install-required' }
  }
  return null
}

export async function currentWebPushState(): Promise<WebPushState> {
  const unavailable = webPushAvailability()
  if (unavailable != null) return unavailable
  if (Notification.permission === 'denied') return { kind: 'blocked' }
  const registration = await serviceWorker()
  const subscription = await registration.pushManager.getSubscription()
  if (subscription == null || Notification.permission !== 'granted') {
    return { kind: 'disabled' }
  }
  const config = await api<WebPushConfigOutput>('/v1/web-push/config')
  if (!subscriptionUsesKey(subscription, config.applicationServerKey)) {
    const endpoint = subscription.endpoint
    await subscription.unsubscribe()
    await deleteSubscription(endpoint)
    return { kind: 'disabled' }
  }
  await putSubscription(subscription, config.applicationServerKey)
  return { kind: 'enabled' }
}

export async function enableWebPush(): Promise<WebPushState> {
  const unavailable = webPushAvailability()
  if (unavailable != null) return unavailable
  const permission = await Notification.requestPermission()
  if (permission !== 'granted') return { kind: 'blocked' }
  const registration = await serviceWorker()
  const config = await api<WebPushConfigOutput>('/v1/web-push/config')
  let subscription = await registration.pushManager.getSubscription()
  if (
    subscription != null &&
    !subscriptionUsesKey(subscription, config.applicationServerKey)
  ) {
    const endpoint = subscription.endpoint
    await subscription.unsubscribe()
    await deleteSubscription(endpoint)
    subscription = null
  }
  subscription ??= await registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: base64URLToBytes(config.applicationServerKey),
  })
  await putSubscription(subscription, config.applicationServerKey)
  return { kind: 'enabled' }
}

export async function disableWebPush(): Promise<WebPushState> {
  const unavailable = webPushAvailability()
  if (unavailable != null) return unavailable
  const registration = await navigator.serviceWorker.getRegistration('/')
  const subscription = await registration?.pushManager.getSubscription()
  if (subscription != null) {
    const endpoint = subscription.endpoint
    await subscription.unsubscribe()
    await deleteSubscription(endpoint)
  }
  return { kind: 'disabled' }
}

export async function removeWebPushSubscription(): Promise<void> {
  if (!('serviceWorker' in navigator)) return
  const registration = await navigator.serviceWorker.getRegistration('/')
  const subscription = await registration?.pushManager.getSubscription()
  if (subscription == null) return
  const endpoint = subscription.endpoint
  await subscription.unsubscribe()
  await deleteSubscription(endpoint)
}

export function base64URLToBytes(value: string): Uint8Array<ArrayBuffer> {
  const normalized = value.replaceAll('-', '+').replaceAll('_', '/')
  const decoded = atob(
    normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '='),
  )
  const bytes = new Uint8Array(decoded.length)
  for (let index = 0; index < decoded.length; index += 1) {
    bytes[index] = decoded.charCodeAt(index)
  }
  return bytes
}

function subscriptionUsesKey(
  subscription: PushSubscription,
  expected: string,
): boolean {
  const actual = subscription.options.applicationServerKey
  if (actual == null) return false
  const bytes = new Uint8Array(actual)
  const expectedBytes = base64URLToBytes(expected)
  return bytes.length === expectedBytes.length &&
    bytes.every((byte, index) => byte === expectedBytes[index])
}

async function serviceWorker(): Promise<ServiceWorkerRegistration> {
  await registerServiceWorker()
  return navigator.serviceWorker.ready
}

async function putSubscription(
  subscription: PushSubscription,
  applicationServerKey: string,
): Promise<void> {
  const json = subscription.toJSON()
  if (json.keys?.p256dh == null || json.keys.auth == null) {
    throw new Error('the browser returned an incomplete push subscription')
  }
  const input: WebPushSubscriptionInput = {
    endpoint: subscription.endpoint,
    p256dh: json.keys.p256dh,
    auth: json.keys.auth,
    applicationServerKey,
    expirationTime: subscription.expirationTime ?? undefined,
  }
  await authorizedRequest('/v1/web-push/subscription', {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(input),
  })
}

async function deleteSubscription(endpoint: string): Promise<void> {
  const input: WebPushSubscriptionDeleteInput = { endpoint }
  await authorizedRequest('/v1/web-push/subscription', {
    method: 'DELETE',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(input),
  })
}
