interface NativeHost {
  top?: unknown
  webkit?: {
    messageHandlers?: Record<string, { postMessage?: unknown } | undefined>
  }
}

// Settings exposes only a top-frame layout signal, not the wuhuShell navigation protocol.
export function isEmbeddedHost(
  host: NativeHost = globalThis as NativeHost,
): boolean {
  return host.top === host &&
    typeof host.webkit?.messageHandlers?.wuhuEmbedded?.postMessage ===
      'function'
}
