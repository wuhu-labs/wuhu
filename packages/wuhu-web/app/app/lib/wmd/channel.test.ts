import { EphemeralStore, LoroDoc, VersionVector } from 'loro-crdt/web'
import type { WmdAccess, WmdServerControl } from '~/lib/contract.gen'
import type { Timer } from '~/sdk/observe'
import {
  type ChannelState,
  openChannel,
  type Socket,
  type SocketEvents,
} from './channel.ts'
import type { Presence, PresenceStore } from './collab.ts'
import { loadLoro } from './loro.ts'

await loadLoro()

function assertEquals<T>(actual: T, expected: T): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const tag = { sync: 1, update: 2, presence: 3, synced: 4 }

class FakeSocket implements Socket {
  readonly sent: (Uint8Array | string)[] = []
  closed = false
  constructor(readonly url: string, readonly events: SocketEvents) {}
  send(frame: Uint8Array | string) {
    if (this.closed) throw new Error('send after close')
    this.sent.push(frame)
  }
  close() {
    this.closed = true
  }
  control(message: object) {
    this.events.text(JSON.stringify(message))
  }
  frame(kind: number, payload: Uint8Array) {
    this.events.binary(new Uint8Array([kind, ...payload]))
  }
  get texts(): unknown[] {
    return this.sent.flatMap((f) =>
      typeof f === 'string' ? [JSON.parse(f)] : []
    )
  }
  binaries(kind: number): Uint8Array[] {
    return this.sent.flatMap((f) =>
      typeof f !== 'string' && f[0] === kind ? [f.subarray(1)] : []
    )
  }
}

class FakeNet {
  readonly sockets: FakeSocket[] = []
  private waiting: ((socket: FakeSocket) => void)[] = []
  open = (url: string, events: SocketEvents): Socket => {
    const socket = new FakeSocket(url, events)
    this.sockets.push(socket)
    this.waiting.shift()?.(socket)
    return socket
  }
  // Resolves with the next socket the channel opens.
  next(): Promise<FakeSocket> {
    return new Promise((resolve) => this.waiting.push(resolve))
  }
}

class FakeTimer implements Timer {
  readonly pending: { delayMs: number; run: () => void }[] = []
  schedule = (delayMs: number, run: () => void) => {
    const entry = { delayMs, run }
    this.pending.push(entry)
    return () => {
      const index = this.pending.indexOf(entry)
      if (index >= 0) this.pending.splice(index, 1)
    }
  }
  fire(delayMs: number) {
    const index = this.pending.findIndex((entry) => entry.delayMs === delayMs)
    if (index < 0) throw new Error(`no timer of ${delayMs} ms pending`)
    const [entry] = this.pending.splice(index, 1)
    entry!.run()
  }
  delays(): number[] {
    return this.pending.map((entry) => entry.delayMs)
  }
}

const welcome = (access: WmdAccess = 'write'): WmdServerControl => ({
  type: 'welcome',
  connection: 'c1',
  name: 'Ada',
  access,
  peers: [],
  rev: 7,
})

const offline = (retryInMs: number, editable = false): ChannelState => ({
  phase: 'offline',
  retryInMs,
  editable,
  lostEdits: false,
})

function text(doc: LoroDoc, value: string) {
  doc.getText('t').insert(doc.getText('t').length, value)
  doc.commit()
}

interface HarnessOptions {
  create?: boolean
  assertion?: (afterRefusal: boolean) => Promise<string | null>
}

function harness(
  { create = false, assertion = () => Promise.resolve('token') }:
    HarnessOptions = {},
) {
  const doc = new LoroDoc()
  const presence: PresenceStore = new EphemeralStore<Record<string, Presence>>(
    30_000,
  )
  const net = new FakeNet()
  const timer = new FakeTimer()
  const states: ChannelState[] = []
  const imports: number[] = []
  const first = net.next()
  const close = openChannel({
    url: 'wss://space/v1/wmd/a.wmd',
    group: 'g',
    doc,
    presence,
    create,
    assertion,
    importing: (change) => {
      imports.push(1)
      change()
    },
    changed: (state) => states.push(state),
    open: net.open,
    timer,
  })
  const phases = () => states.map((state) => state.phase)
  const end = () => {
    close()
    presence.destroy()
  }
  return { doc, presence, net, timer, states, phases, imports, first, end }
}

// Answers the client's sync like the server: synced with the server's version.
async function goLive(
  socket: FakeSocket,
  server: LoroDoc,
  access?: WmdAccess,
) {
  socket.events.opened()
  socket.control(welcome(access))
  socket.frame(tag.synced, server.oplogVersion().encode())
  await Promise.resolve()
}

Deno.test('says hello with the bearer, then syncs from its own version', async () => {
  const h = harness()
  const socket = await h.first
  socket.events.opened()
  assertEquals(socket.texts, [{
    type: 'hello',
    authorization: 'Bearer token',
    group: 'g',
    peer: h.doc.peerIdStr,
    create: false,
  }])
  socket.control(welcome())
  assertEquals(h.phases(), ['connecting', 'syncing'])
  assertEquals(
    socket.binaries(tag.sync).map((v) => VersionVector.decode(v).toJSON()),
    [h.doc.oplogVersion().toJSON()],
  )
  h.end()
})

Deno.test('an unenrolled browser says hello without authorization', async () => {
  const h = harness({ assertion: () => Promise.resolve(null) })
  const socket = await h.first
  socket.events.opened()
  assertEquals(
    (socket.texts[0] as { authorization: unknown }).authorization,
    null,
  )
  h.end()
})

Deno.test('on synced it goes live and sends what the server lacks', async () => {
  const h = harness()
  text(h.doc, 'offline ')
  const server = new LoroDoc()
  const socket = await h.first
  await goLive(socket, server)
  assertEquals(h.phases(), ['connecting', 'syncing', 'live'])
  for (const update of socket.binaries(tag.update)) server.import(update)
  assertEquals(server.getText('t').toString(), 'offline ')
  h.end()
})

Deno.test('a live writer streams its edits and imports the server updates', async () => {
  const h = harness()
  const server = new LoroDoc()
  text(server, 'theirs ')
  const socket = await h.first
  await goLive(socket, server)
  socket.frame(tag.update, server.export({ mode: 'update' }))
  assertEquals(h.doc.getText('t').toString(), 'theirs ')
  assertEquals(h.imports.length, 1)
  text(h.doc, 'mine')
  await Promise.resolve()
  for (const update of socket.binaries(tag.update)) server.import(update)
  assertEquals(server.getText('t').toString(), 'theirs mine')
  h.end()
})

Deno.test('a reader never sends updates', async () => {
  const h = harness()
  text(h.doc, 'local')
  const socket = await h.first
  await goLive(socket, new LoroDoc(), 'read')
  text(h.doc, ' more')
  await Promise.resolve()
  assertEquals(socket.binaries(tag.update).length, 0)
  h.end()
})

Deno.test('an error frame refuses for good', async () => {
  const h = harness()
  const socket = await h.first
  socket.events.opened()
  socket.control({ type: 'error', code: 'forbidden', message: 'no' })
  assertEquals(h.states.at(-1), {
    phase: 'refused',
    code: 'forbidden',
    message: 'no',
    editable: false,
    lostEdits: false,
  })
  assertEquals(socket.closed, true)
  assertEquals(h.timer.delays(), [10_000])
  h.end()
})

Deno.test('a malformed control frame is a protocol violation', async () => {
  const h = harness()
  const socket = await h.first
  socket.events.opened()
  socket.events.text('{"type":"surprise"}')
  assertEquals(h.states.at(-1)?.phase, 'refused')
  assertEquals((h.states.at(-1) as { code: string }).code, 'protocolViolation')
  assertEquals(socket.closed, true)
  h.end()
})

Deno.test('synced before welcome is a protocol violation', async () => {
  const h = harness()
  const socket = await h.first
  socket.events.opened()
  socket.frame(tag.synced, new LoroDoc().oplogVersion().encode())
  assertEquals((h.states.at(-1) as { code: string }).code, 'protocolViolation')
  h.end()
})

Deno.test('a dropped socket reconnects with doubling backoff, reset by a sync', async () => {
  const h = harness()
  const first = await h.first
  first.events.opened()
  first.events.closed()
  assertEquals(h.states.at(-1), offline(500))
  let next = h.net.next()
  h.timer.fire(500)
  const second = await next
  second.events.closed()
  assertEquals(h.states.at(-1), offline(1000))
  next = h.net.next()
  h.timer.fire(1000)
  const third = await next
  third.events.opened()
  third.control(welcome())
  third.events.closed()
  assertEquals(h.states.at(-1), offline(2000, true))
  next = h.net.next()
  h.timer.fire(2000)
  const fourth = await next
  await goLive(fourth, new LoroDoc())
  fourth.events.closed()
  assertEquals(h.states.at(-1), offline(500, true))
  h.end()
})

Deno.test('a server failing every write backs off until it acks one', async () => {
  const h = harness()
  text(h.doc, 'offline')
  const server = new LoroDoc()
  const first = await h.first
  await goLive(first, server)
  first.control({ type: 'error', code: 'internal', message: 'disk full' })
  assertEquals(h.states.at(-1), offline(500, true))
  let next = h.net.next()
  h.timer.fire(500)
  const second = await next
  await goLive(second, server)
  assertEquals(second.binaries(tag.update).length, 1)
  second.control({ type: 'error', code: 'internal', message: 'disk full' })
  assertEquals(h.states.at(-1), offline(1000, true))
  next = h.net.next()
  h.timer.fire(1000)
  const third = await next
  await goLive(third, server)
  third.control({ type: 'ack', count: 1 })
  third.events.closed()
  assertEquals(h.states.at(-1), offline(500, true))
  h.end()
})

Deno.test('a write welcome keeps it editable until a read welcome or a refusal', async () => {
  const h = harness()
  const editable = () => h.states.at(-1)?.editable
  const first = await h.first
  first.events.opened()
  assertEquals(editable(), false)
  first.control(welcome())
  assertEquals(editable(), true)
  first.events.closed()
  assertEquals(editable(), true)
  let next = h.net.next()
  h.timer.fire(500)
  const second = await next
  assertEquals(h.states.at(-1)?.phase, 'connecting')
  assertEquals(editable(), true)
  second.events.opened()
  second.control(welcome('read'))
  assertEquals(editable(), false)
  second.events.closed()
  next = h.net.next()
  h.timer.fire(1000)
  const third = await next
  third.events.opened()
  third.control(welcome())
  assertEquals(editable(), true)
  third.control({ type: 'error', code: 'forbidden', message: 'no' })
  assertEquals(editable(), false)
  h.end()
})

// Live with write and one acked edit, then another edit while offline; returns
// the reconnecting socket.
async function editOffline() {
  const h = harness()
  const server = new LoroDoc()
  const first = await h.first
  await goLive(first, server)
  text(h.doc, 'sent ')
  for (const update of first.binaries(tag.update)) server.import(update)
  first.control({ type: 'ack', count: 1 })
  first.events.closed()
  text(h.doc, 'typed offline')
  const next = h.net.next()
  h.timer.fire(500)
  return { h, server, socket: await next }
}

Deno.test('a read welcome after offline edits says they are lost', async () => {
  const { h, server, socket } = await editOffline()
  await goLive(socket, server, 'read')
  assertEquals(h.states.at(-1)?.phase, 'live')
  assertEquals(h.states.at(-1)?.lostEdits, true)
  h.end()
})

Deno.test('a read welcome with everything stored loses nothing', async () => {
  const h = harness()
  const server = new LoroDoc()
  const first = await h.first
  await goLive(first, server)
  text(h.doc, 'sent')
  for (const update of first.binaries(tag.update)) server.import(update)
  first.events.closed()
  const next = h.net.next()
  h.timer.fire(500)
  await goLive(await next, server, 'read')
  assertEquals(h.states.at(-1)?.lostEdits, false)
  h.end()
})

Deno.test('a refusal before the unsent edits reach the server says they are lost', async () => {
  const { h, socket } = await editOffline()
  socket.events.opened()
  socket.control({ type: 'error', code: 'notFound', message: 'gone' })
  assertEquals(h.states.at(-1)?.phase, 'refused')
  assertEquals(h.states.at(-1)?.lostEdits, true)
  h.end()
})

Deno.test('a refusal of an unacked live edit says it is lost', async () => {
  const h = harness()
  const first = await h.first
  await goLive(first, new LoroDoc())
  text(h.doc, 'bad')
  first.control({ type: 'error', code: 'invalidUpdate', message: 'no' })
  assertEquals(h.states.at(-1)?.lostEdits, true)
  h.end()
})

Deno.test('a refusal after every edit was acked loses nothing', async () => {
  const h = harness()
  const first = await h.first
  await goLive(first, new LoroDoc())
  text(h.doc, 'stored')
  first.control({ type: 'ack', count: 1 })
  first.control({ type: 'error', code: 'forbidden', message: 'revoked' })
  assertEquals(h.states.at(-1)?.lostEdits, false)
  h.end()
})

Deno.test('a peers frame forgets the presence of peers that left', async () => {
  const h = harness()
  const socket = await h.first
  await goLive(socket, new LoroDoc())
  const other = new EphemeralStore<Record<string, Presence>>(30_000)
  other.set('2', { name: 'Ben', color: '#000' })
  other.set('3', { name: 'Cy', color: '#111' })
  socket.frame(tag.presence, other.encodeAll())
  other.destroy()
  assertEquals(h.presence.keys().sort(), ['2', '3'])
  socket.control({
    type: 'peers',
    peers: [{ connection: 'c2', peer: '2', name: 'Ben', access: 'write' }],
  })
  assertEquals(h.presence.keys(), ['2'])
  assertEquals((h.states.at(-1) as { peers: unknown[] }).peers.length, 1)
  h.end()
})

Deno.test('closing stops the socket and every timer', async () => {
  const h = harness()
  const socket = await h.first
  await goLive(socket, new LoroDoc())
  h.end()
  assertEquals(socket.closed, true)
  assertEquals(h.timer.delays(), [])
  text(h.doc, 'after')
  await Promise.resolve()
})

async function settle() {
  for (let i = 0; i < 3; i++) await Promise.resolve()
}

function hello(socket: FakeSocket): { create: boolean } {
  return socket.texts[0] as { create: boolean }
}

Deno.test('only the first hello asks to create the document', async () => {
  const h = harness({ create: true })
  const first = await h.first
  first.events.opened()
  assertEquals(hello(first).create, true)
  first.control(welcome())
  first.events.closed()
  const next = h.net.next()
  h.timer.fire(500)
  const second = await next
  second.events.opened()
  assertEquals(hello(second).create, false)
  h.end()
})

Deno.test('internal and missingDependencies reconnect instead of refusing', async () => {
  const h = harness()
  const first = await h.first
  first.events.opened()
  first.control({ type: 'error', code: 'internal', message: 'log' })
  assertEquals(first.closed, true)
  assertEquals(h.states.at(-1), offline(500))
  let next = h.net.next()
  h.timer.fire(500)
  const second = await next
  second.events.opened()
  second.control({ type: 'error', code: 'missingDependencies', message: 'gap' })
  assertEquals(h.states.at(-1), offline(1000))
  next = h.net.next()
  h.timer.fire(1000)
  await next
  h.end()
})

Deno.test('unauthorized retries once after a refusal, then refuses', async () => {
  const refusals: boolean[] = []
  const h = harness({
    assertion: (afterRefusal) => {
      refusals.push(afterRefusal)
      return Promise.resolve('token')
    },
  })
  const first = await h.first
  first.events.opened()
  first.control({ type: 'error', code: 'unauthorized', message: 'expired' })
  assertEquals(h.states.at(-1)?.phase, 'offline')
  const next = h.net.next()
  h.timer.fire(500)
  const second = await next
  second.events.opened()
  second.control({ type: 'error', code: 'unauthorized', message: 'expired' })
  assertEquals(refusals, [false, true])
  assertEquals(h.states.at(-1), {
    phase: 'refused',
    code: 'unauthorized',
    message: 'expired',
    editable: false,
    lostEdits: false,
  })
  h.end()
})

Deno.test('a failed assertion goes offline and tries again', async () => {
  let failing = true
  const h = harness({
    assertion: () => {
      if (!failing) return Promise.resolve('token')
      failing = false
      return Promise.reject(new Error('indexedDB unavailable'))
    },
  })
  await settle()
  assertEquals(h.states.at(-1), offline(500))
  assertEquals(h.net.sockets.length, 0)
  h.timer.fire(500)
  const socket = await h.first
  socket.events.opened()
  assertEquals(
    (socket.texts[0] as { authorization: string }).authorization,
    'Bearer token',
  )
  h.end()
})

Deno.test('a welcome forgets the presence of peers that left meanwhile', async () => {
  const h = harness()
  const other = new EphemeralStore<Record<string, Presence>>(30_000)
  other.set('2', { name: 'Ben', color: '#000' })
  h.presence.apply(other.encodeAll())
  other.destroy()
  const socket = await h.first
  socket.events.opened()
  socket.control(welcome())
  assertEquals(h.presence.keys(), [])
  h.end()
})
