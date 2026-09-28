import NIOCore
import NIOHTTP2

struct HTTP2HealthCheckState {
  enum Phase: Equatable {
    case idle
    case waiting(NIODeadline)
    case probing(HTTP2PingData, NIODeadline)
    case closed
  }

  let idleInterval: TimeAmount
  let acknowledgementTimeout: TimeAmount
  private(set) var phase = Phase.idle
  private(set) var streams = Set<HTTP2StreamID>()
  private var lastRead = NIODeadline.uptimeNanoseconds(0)
  private var nextNonce: UInt64

  init(idleInterval: TimeAmount, acknowledgementTimeout: TimeAmount, initialNonce: UInt64) {
    nextNonce = initialNonce
    self.idleInterval = idleInterval
    self.acknowledgementTimeout = acknowledgementTimeout
  }

  var deadline: NIODeadline? {
    switch phase {
    case let .waiting(deadline), let .probing(_, deadline): deadline
    case .idle, .closed: nil
    }
  }

  var pendingPing: HTTP2PingData? {
    if case let .probing(id, _) = phase { id } else { nil }
  }

  mutating func streamOpened(_ id: HTTP2StreamID, now: NIODeadline) {
    guard phase != .closed else { return }
    streams.insert(id)
    if phase == .idle {
      lastRead = now
      phase = .waiting(now + idleInterval)
    }
  }

  mutating func streamClosed(_ id: HTTP2StreamID) {
    streams.remove(id)
    if streams.isEmpty, phase != .closed { phase = .idle }
  }

  mutating func received(_ frame: HTTP2Frame, now: NIODeadline) -> Bool {
    lastRead = now
    if case let .ping(id, ack: true) = frame.payload, id == pendingPing {
      phase = .waiting(now + idleInterval)
      return true
    }
    return false
  }

  mutating func timerFired(now: NIODeadline) {
    switch phase {
    case .waiting:
      let nextProbe = lastRead + idleInterval
      if now < nextProbe {
        phase = .waiting(nextProbe)
      } else {
        let id = HTTP2PingData(withInteger: nextNonce)
        nextNonce &+= 1
        phase = .probing(id, now + acknowledgementTimeout)
      }
    case .probing:
      phase = .closed
    case .idle, .closed:
      break
    }
  }

  mutating func stop() {
    phase = .closed
    streams.removeAll()
  }
}
