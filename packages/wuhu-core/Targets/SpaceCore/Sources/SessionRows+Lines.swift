import SessionDomain

extension Sessions {
  /// The lines of a generation's prompt, which the inference writes into its first positions after later lines may already stand.
  public static let promptKeys = ["system"] + openingKeys
}

extension StoredTranscriptLine {
  public var isPrompt: Bool {
    Sessions.promptKeys.contains(key)
  }

  public init(row: SessionLineRow) {
    self.init(
      position: Int(row.position), at: try! SQLiteDateFormat.date(from: row.at), role: TranscriptLine.Role(rawValue: row.role)!,
      key: row.key, message: row.message, meta: row.meta,
    )
  }
}

extension SessionStore {
  /// The generation's last `limit` lines before position `before`, or its newest, in position order; no generation names the current one. `hasEarlier` says lines before the page remain.
  public func lines(_ id: SessionID, generation: Int?, before: Int?, limit: Int) async throws -> (generation: Int, lines: [StoredTranscriptLine], hasEarlier: Bool) {
    return try spaceCell.sessionLinePage(id, generation: generation, before: before, limit: limit)
  }
}
