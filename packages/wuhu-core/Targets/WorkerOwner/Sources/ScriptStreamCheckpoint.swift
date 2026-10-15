#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Fetch.Body
import enum JSONValue.JSONValue
import struct SessionDomain.SessionID
import protocol SessionTools.ScriptOwnerClient
import struct SpaceCore.Rev
import struct SpaceCore.Rows
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError

extension ParentScriptStreams {
  static func source(_ call: WorkerCall, owner: any ScriptOwnerClient, overflow: ScriptWatchOverflow) -> RetainedScriptStream.Source {
    { cursor in
      let values: AsyncThrowingStream<JSONValue, any Error>
      if call.operation == "script.observe-open" {
        let request = try ownerDecode(ObserveRequest.self, call.payload)
        let source = try await owner.observe(request.sql, parameters: request.parameters, session: request.session)
        let reader = RowsStreamReader(source)
        values = AsyncThrowingStream(unfolding: { try await reader.next().map(ownerEncode) })
      } else {
        let request = try ownerDecode(WatchRequest.self, call.payload)
        let from = cursor.revision.map { cursor.acknowledgedInRevision.isEmpty ? $0 : max(0, $0 - 1) }
        values = try await owner.watch(request.glob, from: from.map(Rev.init), session: request.session)
      }
      let filter = ResumedScriptReader(values, cursor: cursor, watch: call.operation == "script.watch-open")
      let filtered = AsyncThrowingStream<JSONValue, any Error>(unfolding: { try await filter.next() })
      return call.operation == "script.watch-open" ? boundedScriptWatch(filtered, onOverflow: overflow.mark) : filtered
    }
  }
}

struct ScriptStreamCheckpoint: Codable, Sendable {
  let definition: WorkerCall
  let reader: ScriptReaderCheckpoint

  func validate() throws {
    let cursor = reader.cursor
    guard (reader.stagedID == nil) == (reader.stagedValue == nil), !reader.ended || reader.stagedID == nil,
          cursor.revision == nil || cursor.revision! >= 0
    else { throw WorkerProtocolError(.invalidMessage, message: "Invalid logical reader cursor") }
    if definition.operation == "script.watch-open" {
      _ = try ownerDecode(WatchRequest.self, definition.payload)
      guard let revision = cursor.revision, cursor.marker == cursor.acknowledgedInRevision.last,
            cursor.acknowledgedInRevision.allSatisfy({ $0.object?["rev"]?.intValue == revision })
      else { throw WorkerProtocolError(.invalidMessage, message: "Invalid watch acknowledgement cursor") }
    } else {
      _ = try ownerDecode(ObserveRequest.self, definition.payload)
      guard !reader.overflowed, cursor.revision == nil, cursor.acknowledgedInRevision.isEmpty else { throw WorkerProtocolError(.invalidMessage, message: "Invalid query acknowledgement cursor") }
    }
  }
}

private actor ResumedScriptReader {
  private let reader: OwnerRecordReader<JSONValue>
  private var initial = true
  private let cursor: ScriptStreamCursor
  private let watch: Bool
  init(_ source: AsyncThrowingStream<JSONValue, any Error>, cursor: ScriptStreamCursor, watch: Bool) {
    reader = OwnerRecordReader(.stream(OwnerRecordSequence(source: source)))
    self.cursor = cursor; self.watch = watch
  }

  func next() async throws -> JSONValue? {
    while let value = try await reader.next() {
      if watch {
        if let revision = cursor.revision, let rev = value.object?["rev"]?.intValue {
          if rev < revision || (rev == revision && (cursor.acknowledgedInRevision.isEmpty || cursor.acknowledgedInRevision.contains(value))) { continue }
        }
      } else if initial, cursor.marker == value {
        initial = false
        continue
      }
      initial = false
      return value
    }
    return nil
  }
}

private actor RowsStreamReader {
  var iterator: AsyncThrowingStream<Rows, any Error>.Iterator?
  init(_ source: AsyncThrowingStream<Rows, any Error>) { iterator = source.makeAsyncIterator() }
  func next() async throws -> RowsSnapshot? {
    guard var iterator else { throw WorkerProtocolError(.invalidMessage, message: "Concurrent query stream reader") }
    self.iterator = nil
    defer { self.iterator = iterator }
    return try await iterator.next(isolation: self).map(RowsSnapshot.init)
  }
}
