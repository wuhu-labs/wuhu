import { useEffect, useRef, useState } from 'react'
import type { SpaceClient } from '~/sdk/client'
import { errorMessage } from '~/sdk/errors'
import { scriptHost } from './browser-host.ts'
import type { ScriptResult, Watching } from './host.ts'

export type ScriptState =
  | { kind: 'loading' }
  | { kind: 'failed'; message: string }
  | { kind: 'ran'; result: ScriptResult }

// Runs one script file live: again when the file changes, when what it read
// changes, and, while active, when a fetch it made goes stale.
function watchScript(
  client: SpaceClient,
  path: string,
  props: unknown,
  active: () => boolean,
  receive: (state: ScriptState) => void,
): { stop(): void; setActive(active: boolean): void } {
  let watching: Watching | null = null
  const stop = client.script(path)(
    (code) => {
      watching?.stop()
      watching = scriptHost(client.group).watch(
        { file: path, code, props, active: active() },
        (result) => receive({ kind: 'ran', result }),
      )
    },
    (failure) => {
      watching?.stop()
      watching = null
      receive({ kind: 'failed', message: errorMessage(failure) })
    },
  )
  return {
    stop() {
      stop()
      watching?.stop()
    },
    setActive: (on) => watching?.setActive(on),
  }
}

export function useScript(
  client: SpaceClient,
  path: string,
  props: unknown,
  active: boolean,
): ScriptState {
  const [state, setState] = useState<ScriptState>({ kind: 'loading' })
  const propsKey = JSON.stringify(props)
  const activeRef = useRef(active)
  const watch = useRef<ReturnType<typeof watchScript> | null>(null)
  useEffect(() => {
    const started = watchScript(
      client,
      path,
      JSON.parse(propsKey),
      () => activeRef.current,
      setState,
    )
    watch.current = started
    return () => {
      started.stop()
      watch.current = null
    }
  }, [client, path, propsKey])
  useEffect(() => {
    activeRef.current = active
    watch.current?.setActive(active)
  }, [active])
  return state
}

// Every sidebar script of a group at once: the rail needs each one's name
// and icon. Only the one on screen is active.
export function useScripts(
  client: SpaceClient,
  paths: readonly string[],
  current: string | null,
  active: boolean,
): ReadonlyMap<string, ScriptState> {
  const [states, setStates] = useState<ReadonlyMap<string, ScriptState>>(
    () => new Map(),
  )
  const key = paths.join('\n')
  const on = useRef({ current, active })
  const watches = useRef(new Map<string, ReturnType<typeof watchScript>>())
  useEffect(() => {
    const started = new Map<string, ReturnType<typeof watchScript>>()
    for (const path of key === '' ? [] : key.split('\n')) {
      started.set(
        path,
        watchScript(
          client,
          path,
          {},
          () => on.current.active && on.current.current === path,
          (state) =>
            setStates((previous) => new Map(previous).set(path, state)),
        ),
      )
    }
    watches.current = started
    return () => {
      for (const watching of started.values()) watching.stop()
    }
  }, [client, key])
  useEffect(() => {
    on.current = { current, active }
    for (const [path, watching] of watches.current) {
      watching.setActive(active && path === current)
    }
  }, [current, active])
  return states
}
