public struct BodyStream: AsyncSequence, Sendable {
  public typealias Element = Bytes
  public struct AsyncIterator: AsyncIteratorProtocol {
    private let storage: BodyStorage
    private let consumer = _BodyStreamConsumer()

    fileprivate init(storage: BodyStorage) {
      self.storage = storage
    }

    public mutating func next() async throws -> Element? {
      try await self.storage.nextChunk(for: ObjectIdentifier(self.consumer))
    }
  }

  let storage: BodyStorage

  init(storage: BodyStorage) {
    self.storage = storage
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(storage: self.storage)
  }
}

private final class _BodyStreamConsumer {}
