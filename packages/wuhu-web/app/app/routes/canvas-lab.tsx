import { useEffect, useRef, useState } from 'react'
import { type CanvasControl, CanvasView } from '~/components/canvas-view'
import { benchPhases, type FrameStats, frameStats } from '~/lib/canvas/bench'
import { boardOf } from '~/lib/canvas/board'
import type { Camera } from '~/lib/canvas/camera'
import { demoDoc } from '~/lib/canvas/demo'
import { boundsOf, type CanvasScene, sceneOf } from '~/lib/canvas/scene'
import { loadLoro } from '~/lib/wmd/loro'

export function meta() {
  return [{ title: 'Canvas lab — Wuhu' }]
}

// The canvas lab: the real renderer over a generated board, no server.
// `?items=500|2000` sizes it, `?zoom=0.25&at=x,y` opens at a scale centred
// on a board point, `?bench=1` runs the scripted pan/zoom on load and
// publishes the frame statistics as `window.canvasBench` (and POSTs them to
// the same-origin path `?report=` names).

interface Built {
  scene: CanvasScene
  items: number
  connectors: number
  buildMs: number
}

declare global {
  var canvasBench: { refresh: number; phases: FrameStats[] } | undefined
}

function frame(): Promise<number> {
  return new Promise((resolve) => requestAnimationFrame(resolve))
}

async function idleRefresh(): Promise<number> {
  let last = await frame()
  const intervals: number[] = []
  for (let i = 0; i < 60; i++) {
    const now = await frame()
    intervals.push(now - last)
    last = now
  }
  return frameStats('idle', intervals, 0).p50
}

export default function CanvasLab() {
  const params = new URLSearchParams(globalThis.location?.search ?? '')
  const count = Number(params.get('items') ?? 2000)
  const [built, setBuilt] = useState<Built | null>(null)
  const [results, setResults] = useState<
    { refresh: number; phases: FrameStats[] } | null
  >(null)
  const [running, setRunning] = useState(false)
  const control = useRef<CanvasControl | null>(null)

  useEffect(() => {
    let live = true
    loadLoro().then(() => {
      const start = performance.now()
      const doc = demoDoc(count)
      const board = boardOf(doc)
      const scene = sceneOf(board)
      const buildMs = performance.now() - start
      doc.free()
      if (live) {
        setBuilt({
          scene,
          items: board.items.length,
          connectors: scene.connectors.length,
          buildMs,
        })
      }
    })
    return () => {
      live = false
    }
  }, [count])

  const initialCamera = ((): Camera | undefined => {
    const zoom = params.get('zoom')
    if (zoom === null || typeof innerWidth === 'undefined') return
    const [x, y] = (params.get('at') ?? '450,390').split(',').map(Number)
    const scale = Number(zoom)
    return {
      x: x - innerWidth / 2 / scale,
      y: y - innerHeight / 2 / scale,
      scale,
    }
  })()

  const bench = async () => {
    const view = control.current
    if (view === null || built === null) return
    setRunning(true)
    setResults(null)
    const refresh = await idleRefresh()
    const viewport = { w: innerWidth, h: innerHeight }
    const centre = { x: viewport.w / 2, y: viewport.h / 2 }
    const bounds = boundsOf(built.scene.items.map((item) => item.frame))!
    const board = { x: bounds.x + bounds.w / 2, y: bounds.y + bounds.h / 2 }
    const phases: FrameStats[] = []
    for (const phase of benchPhases(centre, viewport, board)) {
      view.jump(phase.cameras[0])
      await frame()
      await frame()
      let last = await frame()
      const intervals: number[] = []
      for (const camera of phase.cameras) {
        view.jump(camera)
        const now = await frame()
        intervals.push(now - last)
        last = now
      }
      phases.push(frameStats(phase.name, intervals, refresh))
    }
    const all = { refresh, phases }
    globalThis.canvasBench = all
    setResults(all)
    const report = params.get('report')
    if (report?.startsWith('/')) {
      void fetch(report, {
        method: 'POST',
        body: JSON.stringify({
          ...all,
          items: count,
          viewport: [innerWidth, innerHeight, devicePixelRatio],
          agent: navigator.userAgent,
        }),
      })
    }
    setRunning(false)
  }

  useEffect(() => {
    if (built !== null && params.get('bench') === '1') void bench()
  }, [built])

  if (built === null) return <div className='canvas-lab'>Building…</div>
  return (
    <div className='canvas-lab'>
      <CanvasView
        scene={built.scene}
        imageSrc={() => null}
        initialCamera={initialCamera}
        control={control}
      />
      <div className='canvas-lab-panel'>
        <strong>Canvas lab</strong>
        <span>
          {built.items} items · {built.connectors} connectors · built in{' '}
          {Math.round(built.buildMs)} ms
        </span>
        <span className='canvas-lab-actions'>
          {[500, 2000].map((n) => (
            <a key={n} href={`?items=${n}`} aria-current={n === count}>
              {n}
            </a>
          ))}
          <button type='button' disabled={running} onClick={() => void bench()}>
            {running ? 'Running…' : 'Bench'}
          </button>
        </span>
        {results && (
          <table className='canvas-lab-results'>
            <thead>
              <tr>
                <th>phase</th>
                <th>p50</th>
                <th>p95</th>
                <th>p99</th>
                <th>max</th>
                <th>dropped</th>
              </tr>
            </thead>
            <tbody>
              {results.phases.map((phase) => (
                <tr key={phase.name}>
                  <td>{phase.name}</td>
                  <td>{phase.p50}</td>
                  <td>{phase.p95}</td>
                  <td>{phase.p99}</td>
                  <td>{phase.max}</td>
                  <td>{phase.dropped}/{phase.frames}</td>
                </tr>
              ))}
            </tbody>
            <caption>ms per frame; display {results.refresh} ms</caption>
          </table>
        )}
      </div>
    </div>
  )
}
