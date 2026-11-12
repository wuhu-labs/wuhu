#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// What a reply leaves a session cell to keep warming with: the schedule the wake and the ping count use. Whether to warm at all was decided where the reply was built.
public struct WarmingSchedule: Hashable, Sendable, Codable {
  public var intervalSeconds: Int
  public var lifetimeSeconds: Int
  public var maxPings: Int

  public init(intervalSeconds: Int, lifetimeSeconds: Int, maxPings: Int) {
    self.intervalSeconds = intervalSeconds
    self.lifetimeSeconds = lifetimeSeconds
    self.maxPings = maxPings
  }
}

extension SystemNotification {
  public var isCacheWarming: Bool { kind == .context && subscriptionID == .cacheWarming }

  public static func cacheWarming(id: UUID, at: Date) -> SystemNotification {
    .init(
      id: id, timestamp: at, kind: .context, subscriptionID: .cacheWarming,
      content: .init(text: """
      <cache-warming-notice>
      This system notice keeps the prompt cache warm. It is not a message from a person and creates no reply obligation.
      Judge whether you expect more work soon. If you don't, call the compact tool now with park: true: a parked session gets no more of these notices, and its next generation starts at its next wake. If you do, end this turn without a reply; that is normal.
      </cache-warming-notice>
      """),
    )
  }
}

extension TranscriptItem {
  /// Whether the inference this input leads to is a cache-warming ping's (true) or the model's own work (false); nil for what says neither.
  public var cacheWarmingOrigin: Bool? {
    switch self {
    case .message: return false
    case let .notification(notice):
      if notice.isCacheWarming { return notice.content.text.isEmpty ? nil : true }
      switch notice.kind {
      case .context, .owedReply, .parkReminder: return nil
      case .timer, .spaceObservation, .compactRequest, .requestStall, .script, .exec: return false
      }
    case .assistant, .toolResult, .bookmark, .generationHead: return nil
    }
  }
}

extension [TranscriptLine] {
  /// Warming notices the model has not answered don't count, so the check reads the same when a notice is enqueued and when it is consumed.
  public func reachesCacheWarmingFloor(_ floorTokens: Int, images: ImageLimits) -> Bool {
    let answered = (lastIndex { $0.role == .assistant } ?? -1) + 1
    let counted = enumerated().filter { $0.offset < answered || $0.element.key != LineKey.cacheWarming }.map(\.element)
    return counted.estimatedContextTokens(images: images) >= floorTokens
  }
}
