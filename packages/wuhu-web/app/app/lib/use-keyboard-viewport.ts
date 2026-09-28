import { useEffect, useState } from 'react'
import {
  type KeyboardViewport,
  keyboardViewport,
} from '~/lib/keyboard-viewport'

function textEntryFocused() {
  const active = document.activeElement
  return active instanceof HTMLTextAreaElement ||
    active instanceof HTMLInputElement ||
    (active instanceof HTMLElement && active.isContentEditable)
}

function baselineViewportHeight(visual: VisualViewport) {
  return Math.max(
    visual.height,
    globalThis.innerHeight,
    document.documentElement.clientHeight,
  )
}

function sameViewport(
  left: KeyboardViewport | null,
  right: KeyboardViewport | null,
) {
  return left === right ||
    (left != null && right != null && left.height === right.height &&
      left.offsetTop === right.offsetTop)
}

export function useKeyboardViewport() {
  const [geometry, setGeometry] = useState<KeyboardViewport | null>(null)

  useEffect(() => {
    const visual = globalThis.visualViewport
    if (visual == null) return

    let animationFrame = 0

    const update = () => {
      animationFrame = 0
      const next = keyboardViewport({
        baselineHeight: baselineViewportHeight(visual),
        height: visual.height,
        offsetTop: visual.offsetTop,
        scale: visual.scale,
        textEntryFocused: textEntryFocused(),
      })
      setGeometry((current) => sameViewport(current, next) ? current : next)
    }

    const scheduleUpdate = () => {
      if (animationFrame !== 0) cancelAnimationFrame(animationFrame)
      animationFrame = requestAnimationFrame(update)
    }

    visual.addEventListener('resize', scheduleUpdate)
    visual.addEventListener('scroll', scheduleUpdate)
    document.addEventListener('focusin', scheduleUpdate)
    document.addEventListener('focusout', scheduleUpdate)
    update()

    return () => {
      if (animationFrame !== 0) cancelAnimationFrame(animationFrame)
      visual.removeEventListener('resize', scheduleUpdate)
      visual.removeEventListener('scroll', scheduleUpdate)
      document.removeEventListener('focusin', scheduleUpdate)
      document.removeEventListener('focusout', scheduleUpdate)
    }
  }, [])

  return geometry
}
