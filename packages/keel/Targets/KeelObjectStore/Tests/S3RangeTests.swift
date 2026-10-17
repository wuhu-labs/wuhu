#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import KeelObjectStore
import Synchronization
import Testing

/// An in-memory S3 over a fake transport: PUT, HEAD and GET, with ranges
/// answered as RFC 9110 says (206 with Content-Range, 416 past the end), or,
/// for a `misbehaving` server, answered some other way.
private final class FakeS3: Sendable {
  enum Misbehavior: Sendable {
    /// 200 and the whole object, as a server that ignores Range does.
    case ignoresRange
    /// 206 with the given Content-Range and the bytes asked for.
    case contentRange(String)
    /// 206 with a correct Content-Range and one byte more than it says.
    case longerBody
    /// The given status and Content-Range, and a body that never ends.
    case endless(HTTPResponse.Status, contentRange: String?)
  }

  private let objects = Mutex<[String: Data]>([:])
  private let endlessChunks = Mutex(0)
  /// Chunks of an endless body read so far.
  var endlessChunksRead: Int { endlessChunks.withLock { $0 } }
  let misbehavior: Misbehavior?

  init(misbehaving misbehavior: Misbehavior? = nil) {
    self.misbehavior = misbehavior
  }

  var store: S3ObjectStore {
    S3ObjectStore(
      configuration: S3Configuration(
        endpoint: URL(string: "http://s3.test")!, region: "us-east-1", bucket: "bucket", addressing: .pathStyle,
        credentials: SigV4Credentials(accessKeyID: "key", secretAccessKey: "secret"),
      ),
      fetch: FetchClient { request in try await self.answer(request) },
    )
  }

  private func answer(_ request: Request) async throws -> Response {
    let path = request.url.path
    switch request.method {
    case .put:
      let bytes = try await request.body?.bytes() ?? Data()
      objects.withLock { $0[path] = bytes }
      return Response(status: .ok)
    case .head:
      guard let object = objects.withLock({ $0[path] }) else { return Response(status: .notFound) }
      var headers = HTTPFields()
      headers[.contentLength] = String(object.count)
      return Response(status: .ok, headers: headers)
    case .get:
      guard let object = objects.withLock({ $0[path] }) else { return Response(status: .notFound) }
      guard let range = request.headers["range"] else { return Response(status: .ok, body: .bytes(object)) }
      let bounds = range.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
      let first = bounds[0]
      let last = min(bounds[1], object.count - 1)
      var headers = HTTPFields()
      guard first < object.count else {
        headers[.contentRange] = "bytes */\(object.count)"
        return Response(status: .rangeNotSatisfiable, headers: headers)
      }
      let slice = object[first ... last]
      headers[.contentRange] = "bytes \(first)-\(last)/\(object.count)"
      switch misbehavior {
      case nil:
        return Response(status: .partialContent, headers: headers, body: .bytes(Data(slice)))
      case .ignoresRange?:
        return Response(status: .ok, body: .bytes(object))
      case let .contentRange(value)?:
        headers[.contentRange] = value
        return Response(status: .partialContent, headers: headers, body: .bytes(Data(slice)))
      case .longerBody?:
        return Response(status: .partialContent, headers: headers, body: .bytes(Data(slice) + Data([0x21])))
      case let .endless(status, contentRange)?:
        headers[.contentRange] = contentRange
        return Response(status: status, headers: headers, body: .stream(Endless { self.endlessChunks.withLock { $0 += 1 } }))
      }
    default:
      return Response(status: .methodNotAllowed)
    }
  }
}

@Suite struct S3RangedGetTests {
  @Test func aRangeHonoringServerPassesTheContract() async throws {
    let s3 = FakeS3()
    try await ObjectStoreContract(capabilities: .init(preservesContentType: false)) { s3.store }.rangedGet()
  }

  @Test func anAnswerOtherThanTheRangeAskedForIsATypedError() async throws {
    let misbehaviors: [FakeS3.Misbehavior] = [
      .ignoresRange,
      .contentRange("bytes 0-3/10"),
      .contentRange("bytes 2-3/10"),
      .contentRange("bytes 2-9/10"),
      .contentRange("pages 2-4/10"),
      .contentRange("bytes 2-4/3"),
      .longerBody,
    ]
    for misbehavior in misbehaviors {
      let s3 = FakeS3(misbehaving: misbehavior)
      let key = try ObjectKey("ranged")
      try await s3.store.put(key, bytes: Data("0123456789".utf8))
      do {
        let data = try await s3.store.get(key, bytes: 2 ..< 5)
        Issue.record("\(misbehavior): read \(data.count) bytes as the range")
      } catch let error as ObjectStoreError {
        guard case .rangeNotHonored = error else {
          Issue.record("\(misbehavior): \(error)")
          continue
        }
      }
    }
  }

  @Test(.timeLimit(.minutes(1))) func aRefusedAnswerIsNotRead() async throws {
    let answers: [FakeS3.Misbehavior] = [.endless(.ok, contentRange: nil), .endless(.partialContent, contentRange: "bytes 0-9/10")]
    for answer in answers {
      let s3 = FakeS3(misbehaving: answer)
      let key = try ObjectKey("ranged")
      try await s3.store.put(key, bytes: Data("0123456789".utf8))
      await #expect(throws: ObjectStoreError.self) { try await s3.store.get(key, bytes: 2 ..< 5) }
      #expect(s3.endlessChunksRead == 0)
    }
  }

  @Test func aRangeCutAtTheEndNeedsTheTotalToSaySo() async throws {
    let s3 = FakeS3(misbehaving: .contentRange("bytes 8-9/*"))
    let key = try ObjectKey("ranged")
    try await s3.store.put(key, bytes: Data("0123456789".utf8))
    await #expect(throws: ObjectStoreError.rangeNotHonored(key, "206 with Content-Range bytes 8-9/*")) {
      try await s3.store.get(key, bytes: 8 ..< 20)
    }
  }
}

/// A body that never ends, reporting each chunk it yields.
private struct Endless: AsyncSequence, Sendable {
  let onChunk: @Sendable () -> Void

  func makeAsyncIterator() -> Iterator {
    Iterator(onChunk: onChunk)
  }

  struct Iterator: AsyncIteratorProtocol {
    let onChunk: @Sendable () -> Void

    mutating func next() async throws -> Bytes? {
      onChunk()
      return Data(repeating: 0x61, count: 1 << 16)
    }
  }
}
