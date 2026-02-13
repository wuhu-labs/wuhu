import Foundation
import PiAI
import WuhuAPI

struct WuhuCompactionSettings: Sendable, Hashable {
  var enabled: Bool
  var reserveTokens: Int
  var keepRecentTokens: Int
  var contextWindowTokens: Int

  static func load(model: Model, env: [String: String] = ProcessInfo.processInfo.environment) -> WuhuCompactionSettings {
    let enabled = (env["WUHU_COMPACTION_ENABLED"] ?? "1") != "0"
    let reserveTokens = Int(env["WUHU_COMPACTION_RESERVE_TOKENS"] ?? "") ?? 16384
    let keepRecentTokens = Int(env["WUHU_COMPACTION_KEEP_RECENT_TOKENS"] ?? "") ?? 20000

    let contextWindowTokens: Int = if let v = Int(env["WUHU_COMPACTION_CONTEXT_WINDOW_TOKENS"] ?? "") {
      v
    } else {
      defaultContextWindowTokens(model: model)
    }

    return .init(
      enabled: enabled,
      reserveTokens: max(0, reserveTokens),
      keepRecentTokens: max(0, keepRecentTokens),
      contextWindowTokens: max(1, contextWindowTokens),
    )
  }

  private static func defaultContextWindowTokens(model: Model) -> Int {
    switch model.provider {
    case .openai, .openaiCodex:
      128_000
    case .anthropic:
      200_000
    }
  }
}

enum WuhuCompactionEngine {
  static let summarizationSystemPrompt = """
  You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.

  Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
  """

  private static let summarizationPrompt = """
  The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

  Use this EXACT format:

  ## Goal
  [What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

  ## Constraints & Preferences
  - [Any constraints, preferences, or requirements mentioned by user]
  - [Or \"(none)\" if none were mentioned]

  ## Progress
  ### Done
  - [x] [Completed tasks/changes]

  ### In Progress
  - [ ] [Current work]

  ### Blocked
  - [Issues preventing progress, if any]

  ## Key Decisions
  - **[Decision]**: [Brief rationale]

  ## Next Steps
  1. [Ordered list of what should happen next]

  ## Critical Context
  - [Any data, examples, or references needed to continue]
  - [Or \"(none)\" if not applicable]

  Keep each section concise. Preserve exact file paths, function names, and error messages.
  """

  private static let updateSummarizationPrompt = """
  The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

  Update the existing structured summary with new information. RULES:
  - PRESERVE all existing information from the previous summary
  - ADD new progress, decisions, and context from the new messages
  - UPDATE the Progress section: move items from \"In Progress\" to \"Done\" when completed
  - UPDATE \"Next Steps\" based on what was accomplished
  - PRESERVE exact file paths, function names, and error messages
  - If something is no longer relevant, you may remove it

  Use this EXACT format:

  ## Goal
  [Preserve existing goals, add new ones if the task expanded]

  ## Constraints & Preferences
  - [Preserve existing, add new ones discovered]

  ## Progress
  ### Done
  - [x] [Include previously done items AND newly completed items]

  ### In Progress
  - [ ] [Current work - update based on progress]

  ### Blocked
  - [Current blockers - remove if resolved]

  ## Key Decisions
  - **[Decision]**: [Brief rationale] (preserve all previous, add new)

  ## Next Steps
  1. [Update based on current state]

  ## Critical Context
  - [Preserve important context, add new if needed]

  Keep each section concise. Preserve exact file paths, function names, and error messages.
  """

  private static let turnPrefixSummarizationPrompt = """
  This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

  Summarize the prefix to provide context for the retained suffix:

  ## Original Request
  [What did the user ask for in this turn?]

  ## Early Progress
  - [Key decisions and work done in the prefix]

  ## Context for Suffix
  - [Information needed to understand the retained recent work]

  Be concise. Focus on what's needed to understand the kept suffix.
  """

  struct Preparation: Sendable, Hashable {
    var firstKeptEntryID: Int64
    var messagesToSummarize: [Message]
    var turnPrefixMessages: [Message]
    var isSplitTurn: Bool
    var tokensBefore: Int
    var previousSummary: String?
  }

  struct CutPointResult: Sendable, Hashable {
    var firstKeptEntryIndex: Int
    var turnStartIndex: Int
    var isSplitTurn: Bool
  }

  struct ContextUsageEstimate: Sendable, Hashable {
    var tokens: Int
    var usageTokens: Int
    var trailingTokens: Int
    var lastUsageIndex: Int?
  }

  static func estimateContextTokens(messages: [Message]) -> ContextUsageEstimate {
    guard let usageInfo = lastAssistantUsageInfo(messages: messages) else {
      let trailing = messages.reduce(into: 0) { $0 += estimateTokens(message: $1) }
      return .init(tokens: trailing, usageTokens: 0, trailingTokens: trailing, lastUsageIndex: nil)
    }

    let usageTokens = calculateContextTokens(usage: usageInfo.usage)
    let trailing = messages[(usageInfo.index + 1)...].reduce(into: 0) { $0 += estimateTokens(message: $1) }
    return .init(
      tokens: usageTokens + trailing,
      usageTokens: usageTokens,
      trailingTokens: trailing,
      lastUsageIndex: usageInfo.index,
    )
  }

  static func shouldCompact(contextTokens: Int, settings: WuhuCompactionSettings) -> Bool {
    guard settings.enabled else { return false }
    return contextTokens > settings.contextWindowTokens - settings.reserveTokens
  }

  static func findCutPoint(
    entries: [WuhuSessionEntry],
    startIndex: Int,
    endIndex: Int,
    keepRecentTokens: Int,
  ) -> CutPointResult {
    let cutPoints = findValidCutPoints(entries: entries, startIndex: startIndex, endIndex: endIndex)
    guard !cutPoints.isEmpty else {
      return .init(firstKeptEntryIndex: startIndex, turnStartIndex: -1, isSplitTurn: false)
    }

    var accumulatedTokens = 0
    var cutIndex = cutPoints[0]

    for i in stride(from: endIndex - 1, through: startIndex, by: -1) {
      guard case let .message(persisted) = entries[i].payload else { continue }
      guard let message = persisted.toPiMessage() else { continue }
      accumulatedTokens += estimateTokens(message: message)

      if accumulatedTokens >= keepRecentTokens {
        for c in cutPoints where c >= i {
          cutIndex = c
          break
        }
        break
      }
    }

    let isUserMessage: Bool = {
      guard case let .message(persisted) = entries[cutIndex].payload else { return false }
      guard let message = persisted.toPiMessage() else { return false }
      return message.role == .user
    }()

    let turnStartIndex = isUserMessage ? -1 : findTurnStartIndex(entries: entries, entryIndex: cutIndex, startIndex: startIndex)
    return .init(
      firstKeptEntryIndex: cutIndex,
      turnStartIndex: turnStartIndex,
      isSplitTurn: !isUserMessage && turnStartIndex != -1,
    )
  }

  static func prepareCompaction(
    transcript: [WuhuSessionEntry],
    settings: WuhuCompactionSettings,
  ) -> Preparation? {
    guard let headerIndex = transcript.firstIndex(where: { $0.parentEntryID == nil }) else { return nil }
    let messagesStartIndex = min(headerIndex + 1, transcript.count)

    let lastCompaction = transcript.last { entry in
      if case .compaction = entry.payload { return true }
      return false
    }
    let previousSummary: String? = if case let .compaction(comp) = lastCompaction?.payload { comp.summary } else { nil }
    let boundaryStartIndex: Int = if case let .compaction(comp) = lastCompaction?.payload {
      transcript.firstIndex(where: { $0.id == comp.firstKeptEntryID }) ?? messagesStartIndex
    } else {
      messagesStartIndex
    }
    let boundaryEndIndex = transcript.count

    if boundaryEndIndex - boundaryStartIndex <= 1 { return nil }

    var usageMessages: [Message] = []
    if let previousSummary, !previousSummary.isEmpty {
      usageMessages.append(makeSummaryMessage(summary: previousSummary))
    }
    for entry in transcript[boundaryStartIndex ..< boundaryEndIndex] {
      guard case let .message(persisted) = entry.payload else { continue }
      guard let m = persisted.toPiMessage() else { continue }
      usageMessages.append(m)
    }

    let tokensBefore = estimateContextTokens(messages: usageMessages).tokens
    let cutPoint = findCutPoint(
      entries: transcript,
      startIndex: boundaryStartIndex,
      endIndex: boundaryEndIndex,
      keepRecentTokens: settings.keepRecentTokens,
    )

    let firstKeptEntryIndex = cutPoint.firstKeptEntryIndex
    if firstKeptEntryIndex <= boundaryStartIndex { return nil }

    let historyEndIndex = cutPoint.isSplitTurn ? cutPoint.turnStartIndex : firstKeptEntryIndex
    if historyEndIndex <= boundaryStartIndex { return nil }

    let firstKeptEntryID = transcript[firstKeptEntryIndex].id

    var messagesToSummarize: [Message] = []
    for entry in transcript[boundaryStartIndex ..< historyEndIndex] {
      guard case let .message(persisted) = entry.payload else { continue }
      guard let m = persisted.toPiMessage() else { continue }
      messagesToSummarize.append(m)
    }

    var turnPrefixMessages: [Message] = []
    if cutPoint.isSplitTurn {
      for entry in transcript[cutPoint.turnStartIndex ..< firstKeptEntryIndex] {
        guard case let .message(persisted) = entry.payload else { continue }
        guard let m = persisted.toPiMessage() else { continue }
        turnPrefixMessages.append(m)
      }
    }

    if messagesToSummarize.isEmpty, turnPrefixMessages.isEmpty { return nil }

    return .init(
      firstKeptEntryID: firstKeptEntryID,
      messagesToSummarize: messagesToSummarize,
      turnPrefixMessages: turnPrefixMessages,
      isSplitTurn: cutPoint.isSplitTurn,
      tokensBefore: tokensBefore,
      previousSummary: previousSummary,
    )
  }

  static func generateSummary(
    preparation: Preparation,
    model: Model,
    settings: WuhuCompactionSettings,
    requestOptions: RequestOptions,
    streamFn: StreamFn,
  ) async throws -> String {
    let settingsReserve = max(512, settings.reserveTokens)

    let summaryText: String
    if preparation.isSplitTurn, !preparation.turnPrefixMessages.isEmpty {
      async let history: String = {
        if preparation.messagesToSummarize.isEmpty {
          return preparation.previousSummary ?? "No prior history."
        }
        return try await generateHistorySummary(
          messages: preparation.messagesToSummarize,
          model: model,
          requestOptions: requestOptions,
          reserveTokens: settingsReserve,
          previousSummary: preparation.previousSummary,
          streamFn: streamFn,
        )
      }()
      async let prefix: String = generateTurnPrefixSummary(
        messages: preparation.turnPrefixMessages,
        model: model,
        requestOptions: requestOptions,
        reserveTokens: settingsReserve,
        streamFn: streamFn,
      )
      let (historySummary, turnPrefixSummary) = try await (history, prefix)
      summaryText = "\(historySummary)\n\n---\n\n**Turn Context (split turn):**\n\n\(turnPrefixSummary)"
    } else {
      summaryText = try await generateHistorySummary(
        messages: preparation.messagesToSummarize,
        model: model,
        requestOptions: requestOptions,
        reserveTokens: settingsReserve,
        previousSummary: preparation.previousSummary,
        streamFn: streamFn,
      )
    }

    return summaryText
  }

  private static func generateHistorySummary(
    messages: [Message],
    model: Model,
    requestOptions: RequestOptions,
    reserveTokens: Int,
    previousSummary: String?,
    streamFn: StreamFn,
  ) async throws -> String {
    let maxTokens = min(Int(Double(reserveTokens) * 0.8), 8192)

    let conversationText = serializeConversation(messages: messages)
    var promptText = "<conversation>\n\(conversationText)\n</conversation>\n\n"
    if let previousSummary, !previousSummary.isEmpty {
      promptText += "<previous-summary>\n\(previousSummary)\n</previous-summary>\n\n"
      promptText += updateSummarizationPrompt
    } else {
      promptText += summarizationPrompt
    }

    return try await runSummarization(
      promptText: promptText,
      model: model,
      requestOptions: requestOptions,
      maxTokens: maxTokens,
      streamFn: streamFn,
    )
  }

  private static func generateTurnPrefixSummary(
    messages: [Message],
    model: Model,
    requestOptions: RequestOptions,
    reserveTokens: Int,
    streamFn: StreamFn,
  ) async throws -> String {
    let maxTokens = min(Int(Double(reserveTokens) * 0.5), 4096)
    let conversationText = serializeConversation(messages: messages)
    let promptText = "<conversation>\n\(conversationText)\n</conversation>\n\n\(turnPrefixSummarizationPrompt)"

    return try await runSummarization(
      promptText: promptText,
      model: model,
      requestOptions: requestOptions,
      maxTokens: maxTokens,
      streamFn: streamFn,
    )
  }

  private static func runSummarization(
    promptText: String,
    model: Model,
    requestOptions: RequestOptions,
    maxTokens: Int,
    streamFn: StreamFn,
  ) async throws -> String {
    let user: Message = .user(.init(content: [.text(.init(text: promptText))]))
    let ctx = Context(systemPrompt: summarizationSystemPrompt, messages: [user])

    var opts = requestOptions
    opts.maxTokens = maxTokens
    if model.provider == .openai || model.provider == .openaiCodex,
       model.id.contains("gpt-5") || model.id.contains("codex")
    {
      opts.reasoningEffort = .high
    }

    let stream = try await streamFn(model, ctx, opts)
    let final = try await collectFinalAssistantMessage(from: stream)
    if final.stopReason == .error {
      throw PiAIError.unsupported("Summarization failed: \(final.errorMessage ?? "Unknown error")")
    }

    return final.content.compactMap { block in
      if case let .text(t) = block { return t.text }
      return nil
    }.joined(separator: "\n")
  }

  private static func collectFinalAssistantMessage(
    from stream: AsyncThrowingStream<AssistantMessageEvent, any Error>,
  ) async throws -> AssistantMessage {
    var partial: AssistantMessage?
    var final: AssistantMessage?
    for try await event in stream {
      switch event {
      case let .start(p):
        partial = p
      case let .textDelta(_, p):
        partial = p
      case let .done(message):
        final = message
      }
    }
    if let final { return final }
    if let partial { return partial }
    throw PiAIError.unsupported("No summarization output")
  }

  private static func calculateContextTokens(usage: Usage) -> Int {
    if usage.totalTokens > 0 { return usage.totalTokens }
    return usage.inputTokens + usage.outputTokens
  }

  private static func lastAssistantUsageInfo(messages: [Message]) -> (usage: Usage, index: Int)? {
    for (index, message) in messages.enumerated().reversed() {
      guard case let .assistant(a) = message else { continue }
      guard a.stopReason != .aborted, a.stopReason != .error else { continue }
      guard let usage = a.usage else { continue }
      return (usage, index)
    }
    return nil
  }

  static func estimateTokens(message: Message) -> Int {
    var chars = 0

    switch message {
    case let .user(u):
      chars += estimateChars(content: u.content)
    case let .assistant(a):
      chars += estimateChars(content: a.content)
      if let usage = a.usage {
        chars += String(usage.totalTokens).count
      }
    case let .toolResult(t):
      chars += estimateChars(content: t.content)
      chars += estimateChars(json: t.details)
    }

    return Int(ceil(Double(chars) / 4.0))
  }

  private static func estimateChars(content: [ContentBlock]) -> Int {
    var chars = 0
    for block in content {
      switch block {
      case let .text(t):
        chars += t.text.count
      case let .toolCall(c):
        chars += c.name.count
        chars += estimateChars(json: c.arguments)
      case let .reasoning(r):
        chars += r.encryptedContent?.count ?? 0
        chars += r.summary.reduce(0) { $0 + estimateChars(json: $1) }
      }
    }
    return chars
  }

  private static func estimateChars(json: JSONValue) -> Int {
    switch json {
    case .null:
      4
    case let .bool(v):
      v ? 4 : 5
    case let .number(v):
      String(v).count
    case let .string(v):
      v.count
    case let .array(values):
      values.reduce(2) { $0 + estimateChars(json: $1) + 1 }
    case let .object(values):
      values.reduce(2) { $0 + $1.key.count + estimateChars(json: $1.value) + 2 }
    }
  }

  private static func findValidCutPoints(entries: [WuhuSessionEntry], startIndex: Int, endIndex: Int) -> [Int] {
    var cutPoints: [Int] = []
    cutPoints.reserveCapacity(endIndex - startIndex)

    for i in startIndex ..< endIndex {
      guard case let .message(persisted) = entries[i].payload else { continue }
      guard let message = persisted.toPiMessage() else { continue }
      if message.role == .toolResult { continue }
      cutPoints.append(i)
    }

    return cutPoints
  }

  private static func findTurnStartIndex(entries: [WuhuSessionEntry], entryIndex: Int, startIndex: Int) -> Int {
    for i in stride(from: entryIndex, through: startIndex, by: -1) {
      guard case let .message(persisted) = entries[i].payload else { continue }
      guard let message = persisted.toPiMessage() else { continue }
      if message.role == .user { return i }
    }
    return -1
  }

  static func makeSummaryMessage(summary: String) -> Message {
    let text = "<context-summary>\n\(summary)\n</context-summary>"
    return .user(.init(content: [.text(.init(text: text))]))
  }

  private static func serializeConversation(messages: [Message]) -> String {
    var parts: [String] = []
    parts.reserveCapacity(messages.count)

    for msg in messages {
      switch msg {
      case let .user(u):
        let content = u.content.compactMap { block -> String? in
          if case let .text(t) = block { return t.text }
          return nil
        }.joined()
        if !content.isEmpty { parts.append("[User]: \(content)") }
      case let .assistant(a):
        var textParts: [String] = []
        var toolCalls: [String] = []
        for block in a.content {
          switch block {
          case let .text(t):
            textParts.append(t.text)
          case let .toolCall(c):
            toolCalls.append("\(c.name)(args=\(formatJSON(c.arguments)))")
          case .reasoning:
            continue
          }
        }
        if !textParts.isEmpty { parts.append("[Assistant]: \(textParts.joined(separator: "\n"))") }
        if !toolCalls.isEmpty { parts.append("[Assistant tool calls]: \(toolCalls.joined(separator: "; "))") }
      case let .toolResult(t):
        let content = t.content.compactMap { block -> String? in
          if case let .text(tc) = block { return tc.text }
          return nil
        }.joined()
        if !content.isEmpty { parts.append("[Tool result]: \(content)") }
      }
    }

    return parts.joined(separator: "\n\n")
  }

  private static func formatJSON(_ value: JSONValue) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: value.toAny(), options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8)
    {
      return s
    }
    return "{}"
  }
}
