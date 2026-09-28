// One registration for push and for opening the app offline; its script
// never stores the app's own bundle.
export function registerServiceWorker(): Promise<ServiceWorkerRegistration> {
  return navigator.serviceWorker.register('/_/service-worker.js', {
    type: 'module',
    scope: '/',
  })
}
