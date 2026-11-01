import { type LoroDoc, VersionVector } from 'loro-crdt/web'
import type {
  WmdAccess,
  WmdClientControl,
  WmdErrorCode,
  WmdPeer,
  WmdServerControl,
} from '~/lib/contract.gen'
import type { Timer } from '~/sdk/observe'
import type { PresenceStore } from './collab.ts'

// The live channel of /design/wmd-wire.md, one socket per open document.

export type ChannelPhase =
  | { phase: 'connecting' }
  | {
    phase: 'syncing' | 'live'
    name: string
    access: WmdAccess
    peers: WmdPeer[]
    rev: number | null
  }
  | { phase: 'refused'; code: WmdErrorCode; message: string }
  | { phase: 'offline'; retryInMs: number }

export type ChannelState = ChannelPhase & {
  // From a welcome granting write, through reconnects, until a welcome says
  // read or the channel is refused.
  editable: boolean
  // Local edits the server never stored and this channel will not send: the
  // last welcome said read, or the channel was refused.
  lostEdits: boolean
}

const controlTypes: ReadonlySet<string> = new Set<WmdServerControl['type']>([
  'welcome',
  'ack',
  'peers',
  'checkpoint',
  'error',
])

const tag = { sync: 1, update: 2, presence: 3, synced: 4 } as const

// Codes a fresh handshake can cure; every other code is final.
const transientCodes: ReadonlySet<WmdErrorCode> = new Set<WmdErrorCode>([
  'internal',
  'missingDependencies',
])

const refreshMs = 10_000
const firstBackoffMs = 500
const maxBackoffMs = 10_000

export class WmdProtocolError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'WmdProtocolError'
  }
}

function decodeControl(text: string): WmdServerControl {
  let value: unknown
  try {
    value = JSON.parse(text)
  } catch {
    throw new WmdProtocolError(`control frame is not JSON: ${text}`)
  }
  const type = (value as { type?: unknown } | null)?.type
  if (typeof type !== 'string' || !controlTypes.has(type)) {
    throw new WmdProtocolError(`unknown control frame: ${text}`)
  }
  return value as WmdServerControl
}

export interface SocketEvents {
  opened(): void
  text(data: string): void
  binary(data: Uint8Array): void
  // The peer or the network ended it; never fires after `close()`.
  closed(): void
}

export interface Socket {
  send(frame: Uint8Array | string): void
  close(): void
}

export type OpenSocket = (url: string, events: SocketEvents) => Socket

export const browserSocket: OpenSocket = (url, events) => {
  const ws = new WebSocket(url)
  ws.binaryType = 'arraybuffer'
  ws.onopen = () => events.opened()
  ws.onmessage = (event) => {
    if (typeof event.data === 'string') events.text(event.data)
    else events.binary(new Uint8Array(event.data as ArrayBuffer))
  }
  ws.onclose = () => events.closed()
  return {
    send: (frame) => ws.send(frame),
    close: () => {
      ws.onclose = null
      ws.close()
    },
  }
}

export interface ChannelOptions {
  url: string
  group: string | null
  doc: LoroDoc
  presence: PresenceStore
  // Whether the first hello asks the server to create the missing document;
  // no later hello does, so a deleted document stays deleted.
  create: boolean
  // A fresh bearer assertion, or null for a browser that is not enrolled;
  // `afterRefusal` when the last one was refused as unauthorized.
  assertion(afterRefusal: boolean): Promise<string | null>
  // Runs a Loro import so the editor can follow it.
  importing(change: () => void): void
  changed(state: ChannelState): void
  open: OpenSocket
  timer: Timer
}

function framed(kind: number, payload: Uint8Array): Uint8Array {
  const frame = new Uint8Array(payload.length + 1)
  frame[0] = kind
  frame.set(payload, 1)
  return frame
}

export function wmdChannelURL(path: string, location: Location): string {
  const encoded = path.split('/').map(encodeURIComponent).join('/')
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${scheme}//${location.host}/v1/wmd${encoded}`
}

type Connection =
  | { phase: 'none' }
  | { phase: 'opening'; socket: Socket }
  | { phase: 'open'; socket: Socket }

export function openChannel(options: ChannelOptions): () => void {
  const { doc, presence, timer } = options
  const self = doc.peerIdStr
  let connection: Connection = { phase: 'none' }
  let state: ChannelState = {
    phase: 'connecting',
    editable: false,
    lostEdits: false,
  }
  let closed = false
  let welcomed = false
  let unauthorized = false
  let backoff = firstBackoffMs
  let cancelRetry = () => {}
  let cancelRefresh = () => {}
  // Only this peer's ops can be missing on the server, which appends every
  // op to its log before relaying it; so one counter tracks what is saved.
  let saved = 0
  const inFlight: number[] = []

  const counter = () => doc.oplogVersion().get(self) ?? 0
  const unsaved = () => counter() > saved
  const set = (
    next: ChannelPhase,
    { editable = state.editable, lostEdits = state.lostEdits } = {},
  ) => {
    state = { ...next, editable, lostEdits }
    options.changed(state)
  }
  const sendUpdate = (bytes: Uint8Array) => {
    inFlight.push(counter())
    send(framed(tag.update, bytes))
  }
  const send = (frame: Uint8Array | string) => {
    if (connection.phase === 'open') connection.socket.send(frame)
  }
  const drop = () => {
    if (connection.phase !== 'none') connection.socket.close()
    connection = { phase: 'none' }
    inFlight.length = 0
  }

  const stopUpdates = doc.subscribeLocalUpdates((bytes) => {
    if (state.phase === 'live' && state.access === 'write') sendUpdate(bytes)
  })
  const stopPresence = presence.subscribeLocalUpdates((bytes) => {
    if (state.phase === 'live') send(framed(tag.presence, bytes))
  })
  const refresh = () => {
    cancelRefresh = timer.schedule(refreshMs, () => {
      const mine = presence.get(self)
      if (mine != null && state.phase === 'live') presence.set(self, mine)
      refresh()
    })
  }
  refresh()

  const refuse = (code: WmdErrorCode, message: string) => {
    closed = true
    drop()
    set({ phase: 'refused', code, message }, {
      editable: false,
      lostEdits: unsaved(),
    })
  }
  const retry = () => {
    drop()
    set({ phase: 'offline', retryInMs: backoff })
    cancelRetry = timer.schedule(backoff, () => void connect())
    backoff = Math.min(backoff * 2, maxBackoffMs)
  }
  const prune = (peers: WmdPeer[]) => {
    const present = new Set(peers.map((peer) => peer.peer))
    for (const key of presence.keys()) {
      if (key !== self && !present.has(key)) presence.delete(key)
    }
  }

  const control = (message: WmdServerControl) => {
    switch (message.type) {
      case 'welcome':
        welcomed = true
        unauthorized = false
        prune(message.peers)
        set({
          phase: 'syncing',
          name: message.name,
          access: message.access,
          peers: message.peers,
          rev: message.rev ?? null,
        }, { editable: message.access === 'write', lostEdits: false })
        send(framed(tag.sync, doc.oplogVersion().encode()))
        return
      case 'peers': {
        prune(message.peers)
        if (state.phase === 'live' || state.phase === 'syncing') {
          set({ ...state, peers: message.peers })
        }
        return
      }
      case 'checkpoint':
        if (state.phase === 'live' || state.phase === 'syncing') {
          set({ ...state, rev: message.rev })
        }
        return
      case 'ack': {
        const durable = inFlight.splice(0, message.count)
        if (durable.length > 0) {
          saved = Math.max(saved, ...durable)
          backoff = firstBackoffMs
        }
        return
      }
      case 'error':
        if (transientCodes.has(message.code)) {
          retry()
        } else if (message.code === 'unauthorized' && !unauthorized) {
          // An assertion refused for the clock is cured by a fresh one; the
          // error frame does not say whether that was the reason.
          unauthorized = true
          retry()
        } else {
          refuse(message.code, message.message)
        }
        return
    }
  }

  const binary = (frame: Uint8Array) => {
    const payload = frame.subarray(1)
    switch (frame[0]) {
      case tag.update:
        options.importing(() => doc.import(payload))
        return
      case tag.presence:
        presence.apply(payload)
        return
      case tag.synced: {
        if (state.phase !== 'syncing') {
          throw new WmdProtocolError(`synced while ${state.phase}`)
        }
        const theirs = VersionVector.decode(payload)
        saved = theirs.get(self) ?? 0
        const writing = state.access === 'write'
        set({ ...state, phase: 'live' }, {
          lostEdits: !writing && unsaved(),
        })
        // The channel counts as healthy once the server stores what it
        // lacked, so a server failing every write cannot loop at 500 ms.
        if (!writing || !unsaved()) backoff = firstBackoffMs
        else sendUpdate(doc.export({ mode: 'update', from: theirs }))
        if (presence.get(self) != null) {
          send(framed(tag.presence, presence.encode(self)))
        }
        return
      }
    }
    throw new WmdProtocolError(`unexpected frame tag ${frame[0]}`)
  }

  const guarded = (receive: () => void) => {
    try {
      receive()
    } catch (error) {
      if (!(error instanceof WmdProtocolError)) throw error
      refuse('protocolViolation', error.message)
    }
  }

  const connect = async () => {
    set({ phase: 'connecting' })
    let authorization: string | null
    try {
      authorization = await options.assertion(unauthorized)
    } catch {
      if (!closed) retry()
      return
    }
    if (closed) return
    const socket = options.open(options.url, {
      opened: () => {
        connection = { phase: 'open', socket }
        const hello: WmdClientControl = {
          type: 'hello',
          authorization: authorization == null
            ? null
            : `Bearer ${authorization}`,
          group: options.group,
          peer: self,
          create: options.create && !welcomed,
        }
        send(JSON.stringify(hello))
      },
      text: (data) => guarded(() => control(decodeControl(data))),
      binary: (data) => guarded(() => binary(data)),
      closed: () => {
        connection = { phase: 'none' }
        retry()
      },
    })
    if (connection.phase === 'none') connection = { phase: 'opening', socket }
  }

  void connect()
  return () => {
    closed = true
    cancelRetry()
    cancelRefresh()
    stopUpdates()
    stopPresence()
    drop()
  }
}
