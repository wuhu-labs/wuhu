#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct Body: Sendable {
  public var contentLength: Int64?
  public var contentType: String?

  private let storage: BodyStorage
  private let replayFactory: (@Sendable () -> Body)?

  init(
    contentLength: Int64? = nil,
    contentType: String? = nil,
    storage: BodyStorage,
    replayFactory: (@Sendable () -> Body)?,
  ) {
    self.contentLength = contentLength
    self.contentType = contentType
    self.storage = storage
    self.replayFactory = replayFactory
  }

  public var isReplayable: Bool {
    self.replayFactory != nil
  }

  public var isResolved: Bool {
    get async {
      await self.storage.isResolved
    }
  }

  public func replay() -> Self? {
    self.replayFactory?()
  }

  public func asyncBytes() -> BodyStream {
    BodyStream(storage: self.storage)
  }

  public func bytes(upTo limit: Int? = nil) async throws -> Bytes {
    try await self.storage.collectBytes(limit: limit)
  }

  public func data(upTo limit: Int? = nil) async throws -> Data {
    try await self.bytes(upTo: limit)
  }

  public func text(
    upTo limit: Int? = nil,
    encoding: String.Encoding = .utf8,
  ) async throws -> String {
    let data = try await self.data(upTo: limit)
    guard let string = String(data: data, encoding: encoding) else {
      throw FetchError.invalidTextEncoding
    }
    return string
  }

  public func json<T: Decodable>(
    _ type: T.Type,
    upTo limit: Int? = nil,
    dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .secondsSince1970,
  ) async throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = dateDecodingStrategy
    return try await self.json(type, upTo: limit, decoder: decoder)
  }

  public func json<T: Decodable>(
    _ type: T.Type,
    upTo limit: Int? = nil,
    decoder: JSONDecoder,
  ) async throws -> T {
    try decoder.decode(T.self, from: try await self.data(upTo: limit))
  }

  public func discard() async throws {
    try await self.storage.discard()
  }
}

extension Body {
  public static var empty: Self {
    self.chunks([])
  }

  public static func chunk(
    _ bytes: Bytes,
    contentType: String? = nil,
  ) -> Self {
    self.chunks([bytes], contentType: contentType)
  }

  public static func chunks(
    _ chunks: [Bytes],
    contentType: String? = nil,
  ) -> Self {
    let filteredChunks = chunks.filter { !$0.isEmpty }
    return Self(
      contentLength: Int64(filteredChunks.reduce(0) { $0 + $1.count }),
      contentType: contentType,
      storage: BodyStorage(backing: .buffered(filteredChunks)),
      replayFactory: {
        Self.chunks(filteredChunks, contentType: contentType)
      },
    )
  }

  public static func bytes(
    _ bytes: Bytes,
    contentType: String? = nil,
  ) -> Self {
    self.chunk(bytes, contentType: contentType)
  }

  public static func string(
    _ string: String,
    encoding: String.Encoding = .utf8,
  ) -> Self {
    let data = string.data(using: encoding) ?? Data()
    return Self.bytes(
      data,
      contentType: "text/plain; charset=\(encoding.ianaCharsetName)",
    )
  }

  public static func json<T: Encodable>(
    _ value: T,
    outputFormatting: JSONEncoder.OutputFormatting = [.sortedKeys],
    dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .secondsSince1970,
  ) throws -> Self {
    let encoder = JSONEncoder()
    encoder.outputFormatting = outputFormatting
    encoder.dateEncodingStrategy = dateEncodingStrategy
    return try self.json(value, encoder: encoder)
  }

  public static func json<T: Encodable>(
    _ value: T,
    encoder: JSONEncoder,
  ) throws -> Self {
    let data = try encoder.encode(value)
    return Self.bytes(data, contentType: "application/json")
  }

  public static func stream<S: AsyncSequence & Sendable>(
    length: Int64? = nil,
    contentType: String? = nil,
    _ sequence: S,
  ) -> Self where S.Element == Bytes {
    Self(
      contentLength: length,
      contentType: contentType,
      storage: BodyStorage(backing: .stream(makeIterator: {
        _AnyAsyncIteratorBox(base: sequence.makeAsyncIterator())
      })),
      replayFactory: nil,
    )
  }

  public static func stream<S: AsyncSequence & Sendable>(
    length: Int64? = nil,
    contentType: String? = nil,
    replaying makeSequence: @escaping @Sendable () -> S,
  ) -> Self where S.Element == Bytes {
    Self(
      contentLength: length,
      contentType: contentType,
      storage: BodyStorage(backing: .stream(makeIterator: {
        _AnyAsyncIteratorBox(base: makeSequence().makeAsyncIterator())
      })),
      replayFactory: {
        Self.stream(length: length, contentType: contentType, replaying: makeSequence)
      },
    )
  }
}

actor BodyStorage {
  enum Backing: Sendable {
    case buffered([Bytes])
    case stream(makeIterator: @Sendable () -> _AnyBodyIteratorBox)
  }

  enum Resolution: Sendable {
    case unresolved
    case finished
    case discarded
  }

  let backing: Backing

  private var iterator: _AnyBodyIteratorBox?
  private var bufferedIndex = 0
  private var owner: ObjectIdentifier?
  private var resolution: Resolution = .unresolved
  private var isAdvancing = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(backing: Backing) {
    self.backing = backing
  }

  var isResolved: Bool {
    self.resolution != .unresolved
  }

  func nextChunk(for consumer: ObjectIdentifier) async throws -> Bytes? {
    switch self.resolution {
    case .finished:
      guard self.owner == consumer else {
        throw FetchError.bodyAlreadyConsumed
      }
      return nil

    case .discarded:
      throw FetchError.bodyAlreadyConsumed

    case .unresolved:
      if let owner = self.owner {
        guard owner == consumer else {
          throw FetchError.bodyAlreadyConsumed
        }
      } else {
        self.owner = consumer
      }
      return try await self.nextInternal()
    }
  }

  func collectBytes(limit: Int?) async throws -> Bytes {
    guard self.owner == nil else {
      throw FetchError.bodyAlreadyConsumed
    }
    guard self.resolution == .unresolved else {
      throw FetchError.bodyAlreadyConsumed
    }

    var collected = Data()

    while let chunk = try await self.nextInternal() {
      if let limit, collected.count + chunk.count > limit {
        throw FetchError.bodyLimitExceeded(limit: limit)
      }
      collected.append(contentsOf: chunk)
    }

    return collected
  }

  func discard() async throws {
    guard self.owner == nil else {
      throw FetchError.bodyAlreadyConsumed
    }

    switch self.resolution {
    case .finished, .discarded:
      return

    case .unresolved:
      while try await self.nextInternal() != nil {}
      self.resolution = .discarded
    }
  }

  private func nextInternal() async throws -> Bytes? {
    while self.isAdvancing {
      await withCheckedContinuation { continuation in
        self.waiters.append(continuation)
      }
    }

    self.isAdvancing = true
    defer {
      self.isAdvancing = false
      if !self.waiters.isEmpty {
        self.waiters.removeFirst().resume()
      }
    }

    switch self.backing {
    case let .buffered(chunks):
      guard self.bufferedIndex < chunks.count else {
        self.resolution = .finished
        return nil
      }

      defer {
        self.bufferedIndex += 1
      }
      return chunks[self.bufferedIndex]

    case let .stream(makeIterator):
      let iterator = self.ensureIterator(makeIterator: makeIterator)
      let chunk = try await iterator.next()
      if chunk == nil {
        self.resolution = .finished
      }
      return chunk
    }
  }

  private func ensureIterator(makeIterator: @Sendable () -> _AnyBodyIteratorBox) -> _AnyBodyIteratorBox {
    if let iterator = self.iterator {
      return iterator
    }

    let iterator = makeIterator()
    self.iterator = iterator
    return iterator
  }
}

class _AnyBodyIteratorBox: @unchecked Sendable {
  func next() async throws -> Bytes? {
    fatalError("Override me")
  }
}

final class _AnyAsyncIteratorBox<Base: AsyncIteratorProtocol>: _AnyBodyIteratorBox, @unchecked Sendable
  where Base.Element == Bytes
{
  private var base: Base

  init(base: Base) {
    self.base = base
  }

  override func next() async throws -> Bytes? {
    try await self.base.next()
  }
}

private extension String.Encoding {
  var ianaCharsetName: String {
    switch self {
    case .utf8:
      return "utf-8"
    case .utf16:
      return "utf-16"
    case .utf16BigEndian:
      return "utf-16be"
    case .utf16LittleEndian:
      return "utf-16le"
    case .utf32:
      return "utf-32"
    case .utf32BigEndian:
      return "utf-32be"
    case .utf32LittleEndian:
      return "utf-32le"
    default:
      return "utf-8"
    }
  }
}
