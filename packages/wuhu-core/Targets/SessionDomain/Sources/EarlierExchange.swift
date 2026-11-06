#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// One side of the session's last exchange in a conversation, from before its
/// current generation began.
public struct EarlierMessage: Hashable, Sendable {
  public static let maxBytes = 4 << 10

  public var id: MessageID
  public var sender: Sender
  public var timestamp: Date
  public var text: String

  public init(id: MessageID, sender: Sender, timestamp: Date, text: String) {
    self.id = id
    self.sender = sender
    self.timestamp = timestamp
    self.text = text
  }

  var quoted: String {
    var body = ""
    var taken = 0
    for character in text {
      let piece = escaped(String(character))
      guard body.utf8.count + piece.utf8.count <= Self.maxBytes else { break }
      body += piece
      taken += character.utf8.count
    }
    let total = text.utf8.count
    let cut = taken < total ? "\n[cut at \(taken) of \(total) bytes; read message \(id.rawValue) for the rest]" : ""
    let name = sender.handle.map { "\($0) (\(sender.id))" } ?? sender.id
    return """
    <message id="\(escaped(id.rawValue))" sender="\(escaped(name))" time="\(timestamp.stamped(in: sender.timeZone))">
    \(body)\(cut)
    </message>
    """
  }
}

extension MessageContent {
  // The block goes in the recipient's copy of the text, after the header and
  // before the body, so every surface that shows the session's input shows it
  // and nothing already in the context moves.
  public func following(_ exchange: [EarlierMessage]) -> MessageContent {
    guard !exchange.isEmpty else { return self }
    var shown = self
    shown.text = "<earlier-in-conversation>\n" + exchange.map(\.quoted).joined(separator: "\n")
      + "\n</earlier-in-conversation>\n\n" + text
    return shown
  }
}
