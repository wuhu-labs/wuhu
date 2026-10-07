import Clocks
import enum Credentials.ProviderCredential
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import WuhuAI

struct SocketRegistryIdentity: Hashable, Sendable {
  var provider: String
  var model: String
  var configuration: ModelsDocument.Provider
  var credential: ProviderCredential
}

public actor ResponsesSocketRegistry {
  private struct Entry {
    var identity: SocketRegistryIdentity?
    var session: ResponsesWebSocketSession
    var born: AnyClock<Duration>.Instant
    var idleSince: AnyClock<Duration>.Instant?
    var lease: UUID
  }

  private var stopped = false
  private var entries: [SessionID: Entry] = [:]
  private let clock: AnyClock<Duration>
  private let idleTTL: Duration
  private let maxIdle: Int
  private let maximumAge: Duration
  private let sweepInterval: Duration

  public init(idleTTL: Duration = .seconds(300), maxIdle: Int = 32, maximumAge: Duration = .seconds(55 * 60), sweepInterval: Duration = .seconds(30)) {
    precondition(idleTTL > .zero && maxIdle >= 0 && maximumAge > .zero && sweepInterval > .zero)
    @Dependency(\.continuousClock) var clock
    self.clock = AnyClock(clock)
    self.idleTTL = idleTTL
    self.maxIdle = maxIdle
    self.maximumAge = maximumAge
    self.sweepInterval = sweepInterval
  }

  public func acquire(session id: SessionID, model: ResolvedModel) async throws -> (session: ResponsesWebSocketSession, lease: UUID) {
    guard !stopped, !Task.isCancelled else { throw CancellationError() }
    guard entries[id]?.idleSince != nil || entries[id] == nil else { throw InferenceError.invalidInput(status: 409, body: "Session inference is already active") }
    guard model.transport == .websocket, model.endpoint is any ResponsesEndpoint else {
      await invalidate(id)
      throw InferenceError.invalidInput(status: 422, body: "WebSocket inference requires a Responses endpoint")
    }
    var retired: ResponsesWebSocketSession?
    if let entry = entries[id] {
      if entry.identity != model.socketIdentity || model.socketIdentity == nil || entry.born.duration(to: clock.now) >= maximumAge {
        retired = entry.session
        entries.removeValue(forKey: id)
      }
    }
    let lease = UUID()
    var entry = entries[id] ?? Entry(identity: model.socketIdentity, session: ResponsesWebSocketSession(), born: clock.now, idleSince: clock.now, lease: lease)
    entry.lease = lease
    entry.idleSince = nil
    entries[id] = entry
    await retired?.invalidate()
    guard entries[id]?.lease == lease else { throw CancellationError() }
    return (entry.session, lease)
  }

  public func release(session id: SessionID, lease: UUID) {
    guard entries[id]?.lease == lease else { return }
    entries[id]?.idleSince = clock.now
  }

  public func invalidate(_ id: SessionID, lease: UUID? = nil) async {
    if let lease, entries[id]?.lease != lease { return }
    let entry = entries.removeValue(forKey: id)
    await entry?.session.invalidate()
  }

  public func shutdown() async {
    stopped = true
    let removed = entries
    entries.removeAll()
    for entry in removed.values { await entry.session.invalidate() }
  }

  public func run() async {
    while !Task.isCancelled {
      guard (try? await clock.sleep(for: sweepInterval)) != nil else { break }
      await sweep()
    }
    await shutdown()
  }

  func sweep() async {
    let now = clock.now
    let idle = entries.compactMap { id, entry in entry.idleSince.map { (id, $0, entry.lease) } }.sorted { $0.1 < $1.1 }
    let excess = max(0, idle.count - maxIdle)
    for (index, pair) in idle.enumerated() {
      guard index < excess || pair.1.duration(to: now) >= idleTTL else { continue }
      guard entries[pair.0]?.lease == pair.2, entries[pair.0]?.idleSince == pair.1 else { continue }
      await invalidate(pair.0)
    }
  }
}
