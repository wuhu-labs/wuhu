import JSONValue
import SpaceCore

struct NotificationContent: Hashable, Sendable {
  // Both gateways cap the whole encoded payload near 4 KB (APNs at 4096, web
  // push at 4096 after encryption) and the relay refuses an oversized one
  // outright, so every text field is clipped to its share with room left for
  // the routing data around it.
  static let titleBytes = 256
  static let bodyBytes = 2048

  var title: String
  var subtitle: String?
  var body: String

  var singleLineTitle: String {
    subtitle.map { "\(title) · \($0)" } ?? title
  }
}

extension NotificationContent {
  init(_ kind: NotificationKind, payload: String, origin: NotificationOrigin) {
    let payload = JSONValue.parse(payload)?.object
    func field(_ name: String) -> String? {
      payload?[name]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
    let body = switch kind {
    case .conversationMessage:
      field("text") ?? ""
    case .childFailed:
      "Failed with a request still open and sent no final report" + (field("error").map { ": \($0)" } ?? ".")
    case .requestDeadline:
      "Passed its request deadline with no final report."
    case .sessionSettled:
      field("message") ?? "Finished."
    case .sessionErrored:
      "Stopped with an error" + (field("error").map { ": \($0)" } ?? ".")
    case .sessionDisconnected:
      "Disconnected."
    case .contractorDisconnected:
      "Its contractor disconnected; nothing is running it."
    }
    let title: String
    let subtitle: String?
    switch origin {
    case let .message(sender, box):
      title = sender
      subtitle = box
    case let .session(session):
      title = session
      subtitle = nil
    }
    self.title = clipped(title, toJSONBytes: Self.titleBytes)
    self.subtitle = subtitle.map { clipped($0, toJSONBytes: Self.titleBytes) }
    self.body = clipped(body, toJSONBytes: Self.bodyBytes)
  }
}

// Counts what the text costs once JSON-encoded, escapes included, so a body of
// newlines or quotes cannot double past its share. An escaped byte count is
// never below the UTF-16 length the relay also checks.
func clipped(_ text: String, toJSONBytes limit: Int) -> String {
  guard jsonBytes(text) > limit else { return text }
  let ellipsis = "…"
  var budget = limit - jsonBytes(ellipsis)
  var end = text.startIndex
  for character in text {
    let cost = jsonBytes(character.unicodeScalars)
    guard cost <= budget else { break }
    budget -= cost
    end = text.index(after: end)
  }
  return String(text[..<end]) + ellipsis
}

func jsonBytes(_ text: some StringProtocol) -> Int {
  jsonBytes(text.unicodeScalars)
}

private func jsonBytes(_ scalars: some Sequence<Unicode.Scalar>) -> Int {
  scalars.reduce(0) { $0 + jsonBytes($1) }
}

private func jsonBytes(_ scalar: Unicode.Scalar) -> Int {
  switch scalar {
  case "\"", "\\", "/", "\u{08}", "\t", "\n", "\u{0C}", "\r": 2
  case "\u{00}" ... "\u{1F}": 6
  default: UTF8.width(scalar)
  }
}
