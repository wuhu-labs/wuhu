import Foundation
import PiAI
import WuhuAPI

actor WuhuAsyncBashCompletionRouter {
  private let registry: WuhuAsyncBashRegistry
  private let store: any SessionStore
  private let eventHub: WuhuLiveEventHub
  private let instanceID: String
  private let steerUserJSON: @Sendable (_ sessionID: String, _ jsonText: String, _ timestamp: Date) async -> Void

  private var task: Task<Void, Never>?

  init(
    registry: WuhuAsyncBashRegistry,
    store: any SessionStore,
    eventHub: WuhuLiveEventHub,
    instanceID: String,
    steerUserJSON: @escaping @Sendable (_ sessionID: String, _ jsonText: String, _ timestamp: Date) async -> Void
  ) {
    self.registry = registry
    self.store = store
    self.eventHub = eventHub
    self.instanceID = instanceID
    self.steerUserJSON = steerUserJSON
  }

  func start() {
    guard task == nil else { return }
    task = Task { [registry] in
      let stream = await registry.subscribeCompletions()
      for await completion in stream {
        await self.handle(completion)
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  private func handle(_ completion: WuhuAsyncBashCompletion) async {
    guard completion.ownerID == instanceID else { return }
    guard let sessionID = completion.sessionID else { return }

    let stdoutData = (try? Data(contentsOf: URL(fileURLWithPath: completion.stdoutFile))) ?? Data()
    let stderrData = (try? Data(contentsOf: URL(fileURLWithPath: completion.stderrFile))) ?? Data()

    let stdoutText = String(decoding: stdoutData, as: UTF8.self)
    let stderrText = String(decoding: stderrData, as: UTF8.self)

    var combined = stdoutText
    if !stderrText.isEmpty {
      if !combined.isEmpty, !combined.hasSuffix("\n") { combined += "\n" }
      combined += stderrText
    }

    let truncation = ToolTruncation.truncateTail(combined)
    var outputText = truncation.content.isEmpty ? "(no output)" : truncation.content

    if truncation.truncated {
      let startLine = truncation.totalLines - truncation.outputLines + 1
      let endLine = truncation.totalLines
      if truncation.lastLinePartial {
        let last = combined.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let lastSize = ToolTruncation.formatSize(last.utf8.count)
        if !outputText.isEmpty { outputText += "\n\n" }
        outputText +=
          "[Showing last \(ToolTruncation.formatSize(truncation.outputBytes)) of line \(endLine) (line is \(lastSize)). Full output: \(completion.stdoutFile) (stdout), \(completion.stderrFile) (stderr)]"
      } else if truncation.truncatedBy == "lines" {
        outputText +=
          "\n\n[Showing lines \(startLine)-\(endLine) of \(truncation.totalLines). Full output: \(completion.stdoutFile) (stdout), \(completion.stderrFile) (stderr)]"
      } else {
        outputText +=
          "\n\n[Showing lines \(startLine)-\(endLine) of \(truncation.totalLines) (\(ToolTruncation.formatSize(ToolTruncation.defaultMaxBytes)) limit). Full output: \(completion.stdoutFile) (stdout), \(completion.stderrFile) (stderr)]"
      }
    }

    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let message: JSONValue = .object([
      "id": .string(completion.id),
      "started_at": .string(fmt.string(from: completion.startedAt)),
      "ended_at": .string(fmt.string(from: completion.endedAt)),
      "duration": .number(completion.durationSeconds),
      "exit_code": .number(Double(completion.exitCode)),
      "timed_out": .bool(completion.timedOut),
      "stdout_file": .string(completion.stdoutFile),
      "stderr_file": .string(completion.stderrFile),
      "output": .string(outputText),
    ])

    let jsonText = wuhuEncodeToolJSON(message)

    do {
      let entry = try await store.appendEntry(sessionID: sessionID, payload: .message(.user(.init(
        user: WuhuUserMessage.unknownUser,
        content: [.text(text: jsonText, signature: nil)],
        timestamp: completion.endedAt
      ))))
      await eventHub.publish(sessionID: sessionID, event: .entryAppended(entry))
    } catch {
      // Best-effort: task may outlive the session/service.
    }

    await steerUserJSON(sessionID, jsonText, completion.endedAt)
  }
}

