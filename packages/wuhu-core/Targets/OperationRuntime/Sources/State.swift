#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct OperationProtocol.ChannelDescriptor
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.Offset
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.Verdict
import struct OperationProtocol.WriteReceipt
import struct OperationProtocol.WriteRequest

struct ChannelState: Sendable {
  let descriptor: ChannelDescriptor
  var floor: Offset = .zero
  var acknowledged: Offset = .zero
  var through: Offset = .zero
  var end = false
  var payload: ChannelPayload
  init(_ descriptor: ChannelDescriptor) {
    self.descriptor = descriptor
    payload = descriptor.unit == .bytes ? .init(data: Data()) : .init(records: [])
  }

  func validate(_ value: ChannelPayload) throws {
    guard (descriptor.unit == .bytes && value.data != nil && value.records == nil)
      || (descriptor.unit == .records && value.records != nil && value.data == nil)
    else {
      throw OperationError(.invalidInput)
    }
    if let records = value.records, records.contains(where: { $0.jsonString().utf8.count > descriptor.maxRecordBytes }) {
      throw OperationError(.recordTooLarge)
    }
  }

  mutating func append(_ value: ChannelPayload) throws -> Bool {
    try validate(value)
    guard !end else { throw OperationError(.operationEnded) }
    guard value.byteCount <= descriptor.windowBytes else { throw OperationError(.inputTooLarge) }
    guard payload.byteCount + value.byteCount <= descriptor.windowBytes else { return false }
    let next = try through.advanced(by: value.count)
    if let data = value.data { payload = .init(data: (payload.data ?? Data()) + data) }
    if let records = value.records { payload = .init(records: (payload.records ?? []) + records) }
    through = next
    return true
  }

  mutating func acknowledge(_ offset: Offset) throws {
    guard offset >= floor else { throw OperationError(.offsetExpired, details: ["floor": .string(String(floor.rawValue))]) }
    guard offset <= through else { throw OperationError(.invalidOffset) }
    payload = payload.slice(Int(offset.rawValue - floor.rawValue) ..< payload.count)
    floor = offset
    acknowledged = offset
  }

  func prefix(upTo bytes: Int) -> ChannelPayload {
    if let data = payload.data { return .init(data: Data(data.prefix(bytes))) }
    var size = 0; var count = 0
    for record in payload.records ?? [] {
      let n = record.jsonString().utf8.count
      if size + n > bytes { break }
      size += n; count += 1
    }
    return payload.slice(0 ..< count)
  }

  mutating func write(_ request: WriteRequest) throws -> WriteReceipt {
    try validate(request.payload)
    let requestedEnd = try request.offset.advanced(by: request.payload.count)
    guard request.offset <= through else { throw OperationError(.invalidOffset) }
    if request.offset < through {
      let overlapStart = max(request.offset, floor)
      let overlapEnd = min(requestedEnd, through)
      if overlapEnd > overlapStart {
        let a = request.payload.slice(Int(overlapStart.rawValue - request.offset.rawValue) ..< Int(overlapEnd.rawValue - request.offset.rawValue))
        let b = payload.slice(Int(overlapStart.rawValue - floor.rawValue) ..< Int(overlapEnd.rawValue - floor.rawValue))
        guard a == b else { throw OperationError(.invalidOffset) }
      }
    }
    guard !end || requestedEnd <= through else { throw OperationError(.operationEnded) }
    if request.end && requestedEnd < through { throw OperationError(.invalidOffset) }
    if requestedEnd > through {
      let suffix = request.payload.slice(Int(through.rawValue - request.offset.rawValue) ..< request.payload.count)
      let space = descriptor.windowBytes - payload.byteCount
      let accepted: ChannelPayload
      if let data = suffix.data { accepted = .init(data: Data(data.prefix(space))) }
      else {
        var n = 0; var count = 0
        for record in suffix.records ?? [] {
          let size = record.jsonString().utf8.count
          if n + size > space { break }; n += size; count += 1
        }
        accepted = suffix.slice(0 ..< count)
      }
      _ = try append(accepted)
    }
    if request.end && requestedEnd == through { end = true }
    return .init(acceptedThrough: through, end: end, blocked: requestedEnd > through)
  }
}

struct OperationState: Sendable {
  let id: UUID
  var kind = ""
  var inputs: [String: ChannelState]
  var outputs: [String: ChannelState]
  var leaseDeadline: Duration
  var lastRequest: Duration
  var finishedAt: Duration?
  var stopReason: String?
  var verdict: Verdict?
  var terminalToken: UUID?
  var terminalAcknowledged = false
  /// Output channels whose own poll carried the terminal acknowledgement. A caller acknowledges per channel (an exec relay acks
  /// stdout and stderr in turn, a search acks with no channel and then on its channel), so only once each has may the operation go.
  var terminalAcknowledgedChannels: Set<String> = []
  var outputConsumed: Bool { outputs.values.allSatisfy { $0.end && $0.acknowledged == $0.through } }
  var settled: Bool { verdict != nil && terminalAcknowledged && outputConsumed }
  /// Settled, and acknowledged on every output channel: no caller can still need it.
  var released: Bool { settled && outputs.keys.allSatisfy(terminalAcknowledgedChannels.contains) }
  var bufferReservation: Int {
    inputs.values.reduce(0) { $0 + (verdict == nil || $1.payload.count > 0 ? $1.descriptor.windowBytes : 0) }
      + outputs.values.reduce(0) { $0 + (!$1.end || $1.payload.count > 0 ? $1.descriptor.windowBytes : 0) }
  }

  /// A request inside the lease extends it; one after the lease lapsed finds it expired, whether or not a sweep ran since.
  mutating func renew(now: Duration, lease: Duration) {
    lastRequest = now
    expire(now: now)
    if verdict == nil && stopReason == nil { leaseDeadline = now + lease }
  }

  mutating func expire(now: Duration) {
    if verdict == nil && now >= leaseDeadline { stopReason = stopReason ?? "leaseExpired" }
  }

  mutating func publish(_ result: Verdict, token: UUID, now: Duration) {
    guard verdict == nil else { return }
    verdict = result; terminalToken = token; finishedAt = now
  }

  mutating func finish(_ result: Verdict, token: UUID, now: Duration) {
    publish(result, token: token, now: now)
    for key in outputs.keys { outputs[key]?.end = true }
  }

  func snapshot(channel: String? = nil, limit: Int = 0) -> OperationSnapshot {
    let c = channel.flatMap { outputs[$0] }; let prefix = c?.prefix(upTo: limit)
    return .init(
      operation: id,
      verdict: verdict,
      terminalToken: terminalToken,
      finalOffsets: outputs.filter { $0.value.end }.mapValues(\.through),
      outputConsumed: outputConsumed,
      channel: channel,
      from: c?.floor,
      through: c.flatMap { try? $0.floor.advanced(by: prefix?.count ?? 0) },
      payload: prefix,
      channelEnd: c.map { $0.end && prefix?.count == $0.payload.count } ?? false,
      bufferReservationBytes: bufferReservation,
    )
  }
}
