let resolveContext

export const context = new Promise((resolve) => {
  let resolved = false
  resolveContext = (value) => {
    if (resolved) return
    resolved = true
    resolve(value)
  }
})

export function interceptedNavigation(link, click, pageHref) {
  if (
    click.defaultPrevented ||
    click.button !== 0 ||
    click.metaKey ||
    click.ctrlKey ||
    click.shiftKey ||
    click.altKey
  ) return null
  const target = link.target.toLowerCase()
  if (link.download || (target !== '' && target !== '_self')) return null
  if (/^wuhu:\/(?!\/)/i.test(link.href)) {
    const hostless = new URL(link.href)
    return hostless.pathname + hostless.search + hostless.hash
  }
  const url = new URL(link.href, pageHref)
  const page = new URL(pageHref)
  if (url.origin !== page.origin) return null
  const sameDocument = url.pathname === page.pathname &&
    url.search === page.search
  if (sameDocument && url.hash !== '') return null
  return url.pathname + url.search + url.hash
}

function shellContext(value) {
  if (value == null || typeof value !== 'object' || Array.isArray(value)) {
    return null
  }
  if (value.type !== 'wuhu:context' || value.mode !== 'shell') return null
  return value
}

// A shell inset is the obstruction the host adds on top of the one the
// platform already reports, so the variable carries both and a page adds
// neither itself.
function insetValue(edge, extent) {
  return `calc(${extent}px + env(safe-area-inset-${edge}, 0px))`
}

const edges = ['top', 'left', 'right', 'bottom']

if (typeof window !== 'undefined' && typeof document !== 'undefined') {
  const api = globalThis.wuhu && typeof globalThis.wuhu === 'object'
    ? globalThis.wuhu
    : {}
  Object.defineProperty(api, 'context', { value: context, enumerable: true })
  globalThis.wuhu = api

  // Pages and their query results paint from the worker's cache while the
  // space is unreachable. A native web view has no service workers, and a
  // browser that refuses one (a private window) still gets the live page.
  navigator.serviceWorker?.register('/_/worker.js', {
    type: 'module',
    scope: '/',
  }).catch(() => undefined)

  // The worker painted this page from its cache and has since stored a
  // different one; the next load paints that.
  navigator.serviceWorker?.addEventListener('message', (event) => {
    if (event.data?.type === 'wuhu:fresh') location.reload()
  })

  const accept = (value) => {
    const message = shellContext(value)
    if (!message) return false
    const insets = message.insets
    if (insets && typeof insets === 'object') {
      const root = document.documentElement
      for (const edge of edges) {
        const extent = insets[edge]
        if (typeof extent === 'number' && Number.isFinite(extent)) {
          root.style.setProperty(
            `--wuhu-inset-${edge}`,
            insetValue(edge, extent),
          )
        }
      }
    }
    resolveContext(message)
    return true
  }

  // A click the host cannot carry yet stays the browser's, so a link is never
  // dead while the handshake is in flight.
  const interceptClicks = (send) => {
    addEventListener('click', (event) => {
      const anchor = event.composedPath().find((node) =>
        node instanceof HTMLAnchorElement
      )
      if (!anchor) return
      const path = interceptedNavigation(
        {
          href: anchor.href,
          download: anchor.hasAttribute('download'),
          target: anchor.target,
        },
        event,
        location.href,
      )
      if (path === null) return
      if (!send({ type: 'wuhu:navigate', path })) return
      event.preventDefault()
    }, { capture: true })
  }

  const parent = globalThis.parent
  const native = parent === window
    ? globalThis.webkit?.messageHandlers?.wuhuShell
    : undefined

  if (parent !== window) {
    let shellOrigin
    addEventListener('message', (event) => {
      if (event.source !== parent) return
      const message = shellContext(event.data)
      if (
        !message ||
        typeof message.shellOrigin !== 'string' ||
        event.origin !== message.shellOrigin
      ) return
      shellOrigin = message.shellOrigin
      accept(message)
    })
    const send = (message) => {
      if (shellOrigin === undefined) return false
      parent.postMessage(message, shellOrigin)
      return true
    }
    interceptClicks(send)
    // The host mints a fresh read cookie and reloads this frame.
    navigator.serviceWorker?.addEventListener('message', (event) => {
      if (event.data?.type === 'wuhu:unauthorized') {
        send({ type: 'wuhu:unauthorized' })
      }
    })
    parent.postMessage({ type: 'wuhu:ready' }, '*')
  } else if (native) {
    let delivered = false
    Object.defineProperty(globalThis, '__wuhuShellContext', {
      configurable: true,
      value: (message) => {
        if (accept(message)) delivered = true
      },
    })
    interceptClicks((message) => {
      if (!delivered) return false
      native.postMessage(message)
      return true
    })
    native.postMessage({ type: 'wuhu:ready' })
  } else {
    setTimeout(() => resolveContext({ mode: 'raw' }), 0)
  }
}
