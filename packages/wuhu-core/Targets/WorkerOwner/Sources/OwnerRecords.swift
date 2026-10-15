#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Fetch.Body
import struct Fetch.BodyStream
import enum JSONValue.JSONValue
import struct WorkerProtocol.WorkerProtocolError

struct OwnerRecord: Codable, Sendable {
  let value: JSONValue?
  let fault: OwnerFault?
  let ended: Bool
}

struct OwnerRecordSequence<Value: Encodable & Sendable>: AsyncSequence, Sendable {
  typealias Element = Data
  let source: AsyncThrowingStream<Value, any Error>
  struct AsyncIterator: AsyncIteratorProtocol {
    var source: AsyncThrowingStream<Value, any Error>.Iterator
    var ended = false
    mutating func next() async throws -> Data? {
      guard !ended else { return nil }
      let record: OwnerRecord
      do {
        if let value = try await source.next() {
          record = try .init(value: ownerEncode(value), fault: nil, ended: false)
        } else {
          ended = true
          record = .init(value: nil, fault: nil, ended: true)
        }
      } catch is CancellationError { throw CancellationError() }
      catch {
        ended = true
        record = .init(value: nil, fault: OwnerFault(error), ended: true)
      }
      var data = try JSONEncoder().encode(record)
      guard data.count <= ownerRecordLimit else { throw WorkerProtocolError(.capacityExceeded, message: "Owner stream record exceeds limit") }
      data.append(0x0A)
      return data
    }
  }

  func makeAsyncIterator() -> AsyncIterator { .init(source: source.makeAsyncIterator()) }
}

private let ownerRecordLimit = 64 << 20

actor OwnerRecordReader<Value: Decodable & Sendable> {
  private var iterator: BodyStream.AsyncIterator?
  private var buffer = Data()
  private var ended = false
  init(_ body: Body) { iterator = body.asyncBytes().makeAsyncIterator() }
  func next() async throws -> Value? {
    guard !ended else { return nil }
    guard var iterator else { throw WorkerProtocolError(.invalidMessage, message: "Concurrent owner stream reader") }
    self.iterator = nil
    defer { self.iterator = iterator }
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        let data = buffer[..<newline]
        let record: OwnerRecord
        do { record = try JSONDecoder().decode(OwnerRecord.self, from: data) }
        catch { throw WorkerProtocolError(.invalidMessage, message: "Invalid owner stream record") }
        buffer.removeSubrange(...newline)
        if let fault = record.fault { ended = true; throw try fault.error() }
        if record.ended { ended = true; return nil }
        guard let value = record.value else { throw WorkerProtocolError(.invalidMessage, message: "Missing owner stream record") }
        return try ownerDecode(Value.self, value)
      }
      guard let data = try await iterator.next(isolation: self) else { throw WorkerProtocolError(.unavailable, message: "Owner stream ended before terminal record") }
      buffer.append(data)
      guard buffer.count <= ownerRecordLimit else { throw WorkerProtocolError(.capacityExceeded, message: "Owner stream record exceeds limit") }
    }
  }
}

struct OwnerResourceBytes: AsyncSequence, Sendable {
  typealias Element = Data
  let body: Body
  let finished: @Sendable () async -> Void
  struct AsyncIterator: AsyncIteratorProtocol {
    var base: BodyStream.AsyncIterator
    let finished: @Sendable () async -> Void
    var ended = false
    mutating func next() async throws -> Data? {
      guard !ended else { return nil }
      do {
        let bytes = try await base.next()
        if bytes == nil { ended = true; await finished() }
        return bytes
      } catch {
        ended = true
        await finished()
        throw error
      }
    }
  }

  func makeAsyncIterator() -> AsyncIterator { .init(base: body.asyncBytes().makeAsyncIterator(), finished: finished) }
}
