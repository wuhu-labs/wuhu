// The app's bundle and shell are never stored here: a navigation goes to the
// network, and only when that fails does it take whatever the browser's HTTP
// cache still holds, so a new server build is picked up on the next reload.
// Every path outside /_/ gets the same shell, so a route never opened here
// still starts from the root's.
export async function navigationResponse(request, fetch) {
  try {
    return await fetch(request)
  } catch (error) {
    const cached = (url) =>
      fetch(new Request(url, { mode: 'same-origin', cache: 'only-if-cached' }))
        .catch(() => null)
    const shell = await cached(request.url) ??
      await cached(new URL('/', request.url).href)
    if (shell === null) throw error
    return shell
  }
}

// The SPA runs on the bare host for every group, so a place in another group
// carries `?group=`. The declarative `navigate` names no group; `data` does.
export function notificationDestination(notification) {
  const data = notification.data
  if (data == null) return notification.navigate ?? '/'
  const url = new URL(data.destination, 'https://destination.invalid')
  if (data.group !== 'shared') url.searchParams.set('group', data.group)
  return url.pathname + url.search + url.hash
}

if (
  typeof ServiceWorkerGlobalScope !== 'undefined' &&
  self instanceof ServiceWorkerGlobalScope
) {
  self.addEventListener('install', () => self.skipWaiting())
  self.addEventListener(
    'activate',
    (event) => event.waitUntil(self.clients.claim()),
  )

  self.addEventListener('fetch', (event) => {
    if (event.request.mode !== 'navigate') return
    event.respondWith(
      navigationResponse(event.request, (input) => fetch(input)),
    )
  })

  self.addEventListener('push', (event) => {
    const payload = event.data?.json()
    const notification = payload?.notification
    if (notification == null || typeof notification.title !== 'string') return
    const destination = notificationDestination(notification)
    event.waitUntil(self.registration.showNotification(notification.title, {
      body: notification.body,
      tag: notification.tag,
      icon: notification.icon ?? '/_/icon-192.png',
      badge: notification.badge ?? '/_/icon-192.png',
      timestamp: notification.timestamp,
      data: { destination },
    }))
  })

  self.addEventListener('notificationclick', (event) => {
    event.notification.close()
    const destination = new URL(
      event.notification.data?.destination ?? '/',
      self.location.origin,
    ).href
    event.waitUntil((async () => {
      const windows = await self.clients.matchAll({
        type: 'window',
        includeUncontrolled: true,
      })
      const existing = windows.find((client) =>
        new URL(client.url).origin === self.location.origin
      )
      if (existing != null) {
        await existing.navigate(destination)
        return existing.focus()
      }
      return self.clients.openWindow(destination)
    })())
  })
}
