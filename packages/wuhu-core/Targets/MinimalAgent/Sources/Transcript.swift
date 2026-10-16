#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif
import WuhuAI

/// The conversation so far, one WuhuAI `Message` per JSONL line when it has a file.
struct Transcript {
  private(set) var messages: [Message] = []
  private let path: String?

  init(_ log: AgentLog?) throws(AgentError) {
    switch log {
    case nil:
      path = nil
    case let .new(path):
      let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else {
        throw AgentError(.transcript, errno == EEXIST ? "\(path) exists; continue it with --resume" : "cannot create \(path): errno \(errno)")
      }
      close(descriptor)
      self.path = path
    case let .resume(path):
      self.path = path
      let data: Data
      do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch { throw AgentError(.transcript, "cannot read \(path): \(error)") }
      for (index, line) in data.split(separator: UInt8(ascii: "\n")).enumerated() {
        do { messages.append(try JSONDecoder().decode(Message.self, from: Data(line))) }
        catch { throw AgentError(.transcript, "\(path) line \(index + 1) is not a message") }
      }
    }
  }

  mutating func append(_ message: Message) throws(AgentError) {
    messages.append(message)
    guard let path else { return }
    var line: [UInt8]
    do { line = Array(try JSONEncoder().encode(message)) } catch { throw AgentError(.transcript, "cannot encode a message: \(error)") }
    line.append(UInt8(ascii: "\n"))
    let descriptor = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw AgentError(.transcript, "cannot open \(path): errno \(errno)") }
    defer { close(descriptor) }
    let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard written == line.count else { throw AgentError(.transcript, "cannot append to \(path): errno \(errno)") }
  }

  /// Tool calls a crashed run never answered get an error result; they are never re-run.
  mutating func closeInterruptedCalls() throws(AgentError) {
    guard let last = messages.lastIndex(where: { $0.assistant != nil }) else { return }
    let answered = Set(messages[(last + 1)...].compactMap { $0.toolResult?.toolCallId })
    for case let .toolCall(call) in messages[last].assistant!.content where !answered.contains(call.id) {
      try append(.toolResult(ToolResultMessage(toolCallId: call.id, content: [.text("interrupted: the agent stopped before this call returned; it was not re-run")], isError: true)))
    }
  }
}
