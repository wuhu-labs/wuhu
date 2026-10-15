import Fetch
import struct FetchTunnel.TunnelTransport
import Serve
import SpaceCore
import Synchronization

/// The streamed responses and sockets a person key opened through the wall,
/// so removing the key or its account ends them at once instead of at the
/// client's next signed request. An ended stream finishes cleanly; the client's
/// reconnect then meets the gate's revoked-key 401. Entries live exactly as
/// long as their stream.
final class KeyStreams: Sendable {
  private struct Hold: Sendable {
    let account: AccountID
    let end: @Sendable () -> Void
  }

  private struct Ledger {
    var next: UInt64 = 0
    var holds: [String: [UInt64: Hold]] = [:]
  }

  private let ledger = Mutex(Ledger())

  var count: Int {
    ledger.withLock { $0.holds.values.reduce(0) { $0 + $1.count } }
  }

  func bind(_ result: UpgradeResult, to key: KeyRecord, space: Space) async -> UpgradeResult {
    switch result {
    case var .response(response):
      guard response.body.contentLength == nil else { return result }
      response.body = await endable(response.body, under: key, space: space)
      return .response(response)
    case let .webSocket(session):
      return .webSocket { socket in
        await self.holding(key, space: space, end: socket.close) { await session(socket) }
      }
    case let .boundedWebSocket(limits, subprotocol, session):
      return .boundedWebSocket(limits: limits, subprotocol: subprotocol) { transport in
        await self.holding(key, space: space, end: transport.abort) { await session(transport) }
      }
    }
  }

  func end(pubkey: String) {
    let ended = ledger.withLock { $0.holds.removeValue(forKey: pubkey) } ?? [:]
    for hold in ended.values { hold.end() }
  }

  func end(account: AccountID) {
    let ended = ledger.withLock { ledger in
      var ended: [Hold] = []
      for (pubkey, holds) in ledger.holds where holds.values.first?.account == account {
        ended += holds.values
        ledger.holds[pubkey] = nil
      }
      return ended
    }
    for hold in ended { hold.end() }
  }

  // The pump reads `body` on its own task, so ending stops it wherever `body`
  // is waiting. `end` cancels the pump itself: a removal racing this setup,
  // before `onTermination` is armed, still stops it.
  private func endable(_ body: Body, under key: KeyRecord, space: Space) async -> Body {
    let (chunks, output) = AsyncThrowingStream<Bytes, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let (demand, input) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let pump = Task {
      defer { output.finish(); input.finish() }
      var iterator = body.asyncBytes().makeAsyncIterator()
      do {
        for await _ in demand {
          guard let chunk = try await iterator.next() else { break }
          output.yield(chunk)
        }
      } catch { output.finish(throwing: error) }
    }
    let id = hold(key) { output.finish(); pump.cancel() }
    output.onTermination = { _ in pump.cancel(); self.release(key.pubkey, id) }
    if await !isLive(key, space: space) { output.finish() }
    return .stream(contentType: body.contentType, HostBodyChunks(chunks: chunks, demand: input))
  }

  private func holding(_ key: KeyRecord, space: Space, end: @escaping @Sendable () -> Void, _ body: () async -> Void) async {
    let id = hold(key, end: end)
    defer { release(key.pubkey, id) }
    if await !isLive(key, space: space) { end() }
    await body()
  }

  // Held before this re-read: a removal after the gate's read and before the
  // hold is seen here, one after the hold ends it.
  private func isLive(_ key: KeyRecord, space: Space) async -> Bool {
    (try? await space.credential(pubkey: key.pubkey)) != nil
  }

  private func hold(_ key: KeyRecord, end: @escaping @Sendable () -> Void) -> UInt64 {
    ledger.withLock { ledger in
      let id = ledger.next
      ledger.next += 1
      ledger.holds[key.pubkey, default: [:]][id] = Hold(account: key.account, end: end)
      return id
    }
  }

  private func release(_ pubkey: String, _ id: UInt64) {
    ledger.withLock { ledger in
      ledger.holds[pubkey]?[id] = nil
      if ledger.holds[pubkey]?.isEmpty == true { ledger.holds[pubkey] = nil }
    }
  }
}
