extension SystemNotification {
  var isCacheWarming: Bool { kind == .context && subscriptionID == SubscriptionID("cache-warming") }
}

extension Transcript {
  public var cacheWarmingInputOrigin: Bool? {
    for item in items.reversed() {
      switch item {
      case .direct, .message: return false
      case let .notification(notice):
        if notice.isCacheWarming, !notice.content.text.isEmpty { return true }
        switch notice.kind {
        case .context, .owedReply, .parkReminder: continue
        case .timer, .spaceObservation, .compactRequest, .childFailed, .requestDeadline, .script: return false
        }
      case .assistant, .toolResult, .bookmark, .generationHead: continue
      }
    }
    return nil
  }
}

extension Transcript {
  public var hasPendingCacheWarming: Bool { !pendingCacheWarmingIndices.isEmpty }

  public func discardingPendingCacheWarming() -> Transcript {
    var transcript = self
    guard let firstWarming = pendingCacheWarmingIndices.first else { return transcript }
    for index in firstWarming ..< items.count {
      guard case var .notification(notice) = transcript.items[index],
            notice.isCacheWarming || (notice.kind == .context && notice.subscriptionID == SubscriptionID("context-pressure")) else { continue }
      notice.content.text = ""
      transcript.items[index] = .notification(notice)
    }
    return transcript
  }

  private var pendingCacheWarmingIndices: [Int] {
    let start = items.lastIndex { if case .assistant = $0 { true } else { false } }.map { $0 + 1 } ?? 0
    return items.indices.filter { index in
      guard index >= start, case let .notification(notice) = items[index] else { return false }
      return notice.isCacheWarming && !notice.content.text.isEmpty
    }
  }
}
