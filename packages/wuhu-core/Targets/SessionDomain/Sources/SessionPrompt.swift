import Foundation

public enum SessionPrompt {
  public static let owedReplyTemplate: String =
    "Your text was not delivered: assistant text is private monologue and the asker never sees it. Do not write more prose — call send_message now in each conversation still waiting on you: {conversations}. If you will answer something later, say so now and nudge when done. Register a subscription instead only if you legitimately must wait."

  public static func owedReply(conversations: [String]) -> String {
    owedReplyTemplate.replacingOccurrences(
      of: "{conversations}",
      with: conversations.joined(separator: ", "),
    )
  }

  public static func compactionNudge(session: SessionID) -> String {
    "Context was compacted; your home is \(session.homePath)/, re-read AGENTS.md and any notes you keep there."
  }

  public static let parkReminderTemplate: String =
    "Request {request} is still open and nothing is scheduled to wake you. Finish the work and call report(request_id: \"{request}\", kind: \"final\", content: ...), or arm a timer if you must genuinely wait."

  public static func parkReminder(request: String) -> String {
    parkReminderTemplate.replacingOccurrences(of: "{request}", with: request)
  }
}
