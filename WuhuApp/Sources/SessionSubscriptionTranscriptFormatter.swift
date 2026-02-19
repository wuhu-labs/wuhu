import Foundation
import WuhuAPI
import WuhuCore

struct SessionSubscriptionTranscriptFormatter: Sendable {
  var verbosity: WuhuSessionVerbosity

  func format(_ items: [TranscriptItem]) -> [WuhuSessionDisplayItem] {
    items.compactMap { item in
      let id = "entry.\(item.id.rawValue)"

      switch item.entry {
      case let .message(m):
        let text: String = switch m.content {
        case let .text(t):
          t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }

        let (role, title) = displayRoleAndTitle(author: m.author)
        return .init(id: id, role: role, title: title, text: text)

      case let .tool(t):
        let title = "Tool:"
        let text = ([t.name] + [t.detail].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return .init(id: id, role: .tool, title: title, text: text)

      case let .marker(m):
        guard verbosity != .compact else {
          // Keep markers only in full/minimal for now.
          break
        }
        return .init(id: id, role: .meta, title: "", text: markerText(m))

      case let .diagnostic(d):
        return .init(id: id, role: .meta, title: "", text: d.message)
      }

      return nil
    }
  }

  private func displayRoleAndTitle(author: Author) -> (WuhuSessionDisplayRole, String) {
    switch author {
    case .system:
      return (.system, "System:")

    case let .participant(participant, kind):
      switch kind {
      case .human:
        let name = participant.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
          return (.user, "User:")
        }
        return (.user, "\(name):")

      case .bot:
        let name = participant.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "agent" {
          return (.agent, "Agent:")
        }
        return (.agent, "\(name):")
      }

    case .unknown:
      return (.user, "User:")
    }
  }

  private func markerText(_ marker: MarkerEntry) -> String {
    switch marker {
    case let .executionStopped(by):
      "Execution stopped by \(authorName(by))"
    case let .executionResumed(trigger):
      "Execution resumed by \(authorName(trigger))"
    case let .participantJoined(author):
      "Participant joined: \(authorName(author))"
    }
  }

  private func authorName(_ author: Author) -> String {
    switch author {
    case .system:
      "system"
    case let .participant(p, _):
      p.rawValue
    case .unknown:
      "unknown"
    }
  }
}
