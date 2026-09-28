import MachineChannel
import MachineContract
import Synchronization

struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

func randomBytes(_ count: Int, using rng: inout SplitMix64) -> [UInt8] {
  (0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
}

func randomChunks(of bytes: [UInt8], maxChunk: Int, using rng: inout SplitMix64) -> [[UInt8]] {
  var chunks: [[UInt8]] = []
  var index = 0
  while index < bytes.count {
    let end = min(index + Int.random(in: 1 ... maxChunk, using: &rng), bytes.count)
    chunks.append(Array(bytes[index ..< end]))
    index = end
  }
  return chunks
}

func execID(_ n: Int) -> ExecID {
  let digits = String(n)
  return ExecID(rawValue: "ex_t" + String(repeating: "0", count: 7 - digits.count) + digits)
}

func makeStart(_ id: ExecID, command: [String] = ["true"], window: Int? = nil) -> ExecStart {
  ExecStart(id: id, cwd: "/", command: command, env: nil, secrets: nil, window: window, maxOutput: nil, timeout: nil)
}

func outputFrame(_ id: ExecID, cursor: Int, bytes: [UInt8]) -> [UInt8] {
  FrameCodec.encode(Frame(streamID: 1, opcode: .output, payload: OutputChunk(id: id, stream: .stdout, cursor: cursor, data: Base64Data(bytes))))
}

func exitFrame(_ id: ExecID, cursor: Int) -> [UInt8] {
  FrameCodec.encode(Frame(streamID: 1, opcode: .execExit, payload: ExecExit(id: id, cursor: cursor, status: .exited(code: 42))))
}

func stdinFrame(_ id: ExecID, cursor: Int, bytes: [UInt8]) -> [UInt8] {
  FrameCodec.encode(Frame(streamID: 1, opcode: .stdin, payload: StdinChunk(id: id, cursor: cursor, data: Base64Data(bytes))))
}

func eofFrame(_ id: ExecID, cursor: Int) -> [UInt8] {
  FrameCodec.encode(Frame(streamID: 1, opcode: .stdinEof, payload: StdinEOF(id: id, cursor: cursor)))
}

final class Box<Value: Sendable>: Sendable {
  private let storage: Mutex<Value>

  init(_ value: Value) {
    storage = Mutex(value)
  }

  var value: Value {
    storage.withLock { $0 }
  }

  func update(_ transform: @Sendable (inout Value) -> Void) {
    storage.withLock { transform(&$0) }
  }
}

struct Checkpoint: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func signal() {
    continuation.yield(())
  }

  func wait() async {
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()
  }
}

func drive(_ x: ChannelEndpoint, _ y: ChannelEndpoint, budgets: [Int] = []) async {
  for budget in budgets {
    let (a, b) = InMemoryTransport.pair(severAfterSends: budget)
    async let left: Void = x.run(a)
    async let right: Void = y.run(b)
    _ = await (left, right)
  }
  let (a, b) = InMemoryTransport.pair()
  async let left: Void = x.run(a)
  async let right: Void = y.run(b)
  _ = await (left, right)
}

func serveEcho(_ endpoint: ChannelEndpoint, stdinLog: Box<[ExecID: [UInt8]]>? = nil, startCounts: Box<[ExecID: Int]>? = nil) async {
  await withTaskGroup(of: Void.self) { group in
    for await exec in endpoint.incomingExecs {
      startCounts?.update { $0[exec.start.id, default: 0] += 1 }
      group.addTask {
        var collected: [UInt8] = []
        do {
          for try await chunk in exec.stdin {
            collected += chunk
          }
          let bytes = collected
          stdinLog?.update { $0[exec.start.id] = bytes }
          try await exec.send(.stdout, bytes)
          await exec.exit(.exited(code: 0))
        } catch {}
      }
    }
  }
}

func serveRequestsOK(_ endpoint: ChannelEndpoint) async {
  for await request in endpoint.inboundRequests {
    switch request {
    case let .vfs(request): await endpoint.respond(.vfs(VFSResponse(id: request.id, result: .ok)))
    case let .search(request): await endpoint.respond(.search(SearchResponse(id: request.id, result: .paths(paths: [], cursor: nil))))
    case let .vaultSet(request): await endpoint.respond(.vaultSet(.ok(id: request.id)))
    case let .vaultRemove(request): await endpoint.respond(.vaultRemove(.ok(id: request.id)))
    case let .vaultList(request): await endpoint.respond(.vaultList(.names(id: request.id, names: ["A"])))
    }
  }
}

// RPCs fail fast with .severed while an endpoint is unbound; tests that race
// the first bind retry through it.
func vfsRetryingUntilBound(_ endpoint: ChannelEndpoint, _ op: VFSOp) async throws -> VFSResult {
  while true {
    do {
      return try await endpoint.vfs(op)
    } catch ChannelError.severed {
      await Task.yield()
    }
  }
}

final class TapTransport: FrameTransport, Sendable {
  let base: InMemoryTransport
  let sent: Box<[Frame]>

  init(_ base: InMemoryTransport) {
    self.base = base
    sent = Box([])
  }

  var inbound: AsyncStream<[UInt8]> {
    base.inbound
  }

  func send(_ frame: [UInt8]) async throws {
    let decoded = try FrameCodec.decode(frame)
    sent.update { $0.append(decoded) }
    try await base.send(frame)
  }

  func close() {
    base.close()
  }

  func outputChunks() -> [OutputChunk] {
    sent.value.filter { $0.opcode == .output }.compactMap { try? $0.payload(OutputChunk.self) }
  }

  func outputBytes() -> Int {
    outputChunks().reduce(0) { $0 + $1.data.count }
  }
}

struct CollectedExec {
  var stdout: [UInt8] = []
  var stderr: [UInt8] = []
  var exit: ExitStatus?
}

func collect(_ exec: OutgoingExec, expectContiguousCursors: Bool = true) async throws -> CollectedExec {
  var collected = CollectedExec()
  var merged = 0
  for try await event in exec.events {
    switch event {
    case let .output(stream, cursor, data):
      if expectContiguousCursors, cursor != merged {
        throw ChannelError.protocolViolation("non-contiguous cursor \(cursor), expected \(merged)")
      }
      merged += data.count
      switch stream {
      case .stdout: collected.stdout += data.bytes
      case .stderr: collected.stderr += data.bytes
      }
    case let .exit(status):
      collected.exit = status
    default:
      break
    }
  }
  return collected
}
