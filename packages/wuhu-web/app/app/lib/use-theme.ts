import { useEffect, useRef } from 'react'

export function useThemeStylesheet(origin: string | null, rev: number) {
  const current = useRef<HTMLLinkElement | null>(null)
  useEffect(() => {
    if (!origin) return
    return () => {
      current.current?.remove()
      current.current = null
    }
  }, [origin])
  useEffect(() => {
    if (!origin) return
    const previous = current.current
    const link = document.createElement('link')
    link.rel = 'stylesheet'
    link.href = `${origin}/theme.css?rev=${rev}`
    if (previous) {
      // Swap old for new only once the new sheet settles, so a live edit
      // restyles without a flash of unthemed content.
      const drop = () => previous.remove()
      link.addEventListener('load', drop)
      link.addEventListener('error', drop)
    }
    current.current = link
    document.head.append(link)
  }, [origin, rev])
}
