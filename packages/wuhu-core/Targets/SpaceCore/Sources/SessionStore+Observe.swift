import struct SpaceIDs.ConversationID
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries

public struct TranscriptCursor: Hashable, Sendable {
  public var generation: Int
  public var position: Int

  public init(generation: Int, position: Int) {
    self.generation = generation
    self.position = position
  }
}

extension SessionStore {
  public func observeConversation(
    _ conversation: ConversationID,
    after n: Int64 = 0,
    as principal: Principal? = nil,
  ) async throws -> AsyncThrowingStream<[MessageRecord], any Error> {
    let (stream, continuation) = AsyncThrowingStream<[MessageRecord], any Error>.makeStream()
    guard let peer = try await runtime.worker().attach(ConversationTail.self, to: ConversationCell.ID(conversation.rawValue), opening: .init(after: n, viewer: principal), output: { output in
      switch output {
      case let .frame(messages): continuation.yield(messages)
      case .closed: continuation.finish(throwing: SessionStoreError.unknownConversation(conversation.rawValue))
      }
    }) else { throw SessionStoreError.unknownConversation(conversation.rawValue) }
    continuation.onTermination = { _ in peer.close() }
    return stream
  }
}
