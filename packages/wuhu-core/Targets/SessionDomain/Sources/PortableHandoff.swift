import WuhuAI

public struct ReplayBinding: Hashable, Sendable, Codable {
  public var identity: String
  public var epoch: String

  public init(identity: String, epoch: String) {
    self.identity = identity
    self.epoch = epoch
  }
}

extension Message {
  /// The message as another account can replay it: encrypted reasoning leaves its summary or nothing, a hosted tool's record its digest.
  public var portable: Message {
    guard case var .assistant(reply) = self else { return self }
    reply.content = reply.content.compactMap { block in
      switch block {
      case let .reasoning(.encrypted(content)):
        guard !content.redacted, let summary = content.summary, !summary.isEmpty else { return nil }
        return .text(summary)
      case let .hostedTool(content): return .text(content.digest)
      default: return block
      }
    }
    return .assistant(reply)
  }
}

extension [TranscriptLine] {
  /// Where the newest lines worth `tokens` begin, never inside a tool turn: every answer kept has its call kept. Nil when not even the last turn fits.
  public func recentTail(tokens: Int, images: ImageLimits) -> Int? {
    var first: Int?
    var sum = 0
    var awaiting: Set<String> = []
    for index in indices.reversed() {
      let message = self[index].message
      sum += message.estimatedTokens(images)
      switch message {
      case let .toolResult(result): awaiting.insert(result.toolCallId)
      case let .assistant(reply):
        for case let .toolCall(call) in reply.content { awaiting.remove(call.id) }
      case .user: break
      }
      guard awaiting.isEmpty else { continue }
      guard sum <= tokens else { break }
      first = index
    }
    return first
  }
}
