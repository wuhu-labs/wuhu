import { useEffect, useState } from 'react'

// Whether this tab is on screen.
export function usePageVisible(): boolean {
  const [visible, setVisible] = useState(
    () => document.visibilityState === 'visible',
  )
  useEffect(() => {
    const changed = () => setVisible(document.visibilityState === 'visible')
    document.addEventListener('visibilitychange', changed)
    return () => document.removeEventListener('visibilitychange', changed)
  }, [])
  return visible
}
