import Foundation
import PiAgent
import PiAI
import WuhuAPI

public actor WuhuLLMRequestLogger {
  public enum Purpose: String, Sendable, Codable, Hashable {
    case agent
    case compaction
  }

  private let directoryURL: URL
  private var sequence: Int64 = 0

  public init(directoryURL: URL) throws {
    self.directoryURL = directoryURL
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  }

  public nonisolated func makeLoggedStreamFn(
    base: @escaping StreamFn,
    sessionID: String,
    purpose: Purpose,
  ) -> StreamFn {
    { model, context, options in
      let startedAt = Date()
      let request = WuhuLLMRequestSnapshot(
        model: .init(from: model),
        context: .init(from: context),
        options: .init(from: options),
      )

      let underlying = try await base(model, context, options)

      return AsyncThrowingStream(AssistantMessageEvent.self, bufferingPolicy: .bufferingNewest(1024)) { continuation in
        let task = Task {
          var finalMessage: AssistantMessage?
          do {
            for try await event in underlying {
              if case let .done(message) = event {
                finalMessage = message
              }
              continuation.yield(event)
            }

            let finishedAt = Date()
            await self.writeLog(
              .init(
                version: 1,
                sessionID: sessionID,
                purpose: purpose,
                startedAt: startedAt,
                finishedAt: finishedAt,
                request: request,
                response: finalMessage.map { .init(from: $0) },
                error: nil,
              ),
            )
            continuation.finish()
          } catch {
            let finishedAt = Date()
            await self.writeLog(
              .init(
                version: 1,
                sessionID: sessionID,
                purpose: purpose,
                startedAt: startedAt,
                finishedAt: finishedAt,
                request: request,
                response: finalMessage.map { .init(from: $0) },
                error: "\(error)",
              ),
            )
            continuation.finish(throwing: error)
          }
        }

        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    }
  }

  private func writeLog(_ log: WuhuLLMRequestLog) async {
    sequence += 1
    let seq = sequence

    let fileURL = directoryURL.appendingPathComponent(fileName(startedAt: log.startedAt, sequence: seq, sessionID: log.sessionID, purpose: log.purpose))
    do {
      let data = try WuhuJSON.encoder.encode(log)
      try data.write(to: fileURL, options: [.atomic])
    } catch {
      // Best-effort: logging must never crash the server.
    }
  }

  private func fileName(startedAt: Date, sequence: Int64, sessionID: String, purpose: Purpose) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(secondsFromGMT: 0)
    fmt.dateFormat = "yyyyMMdd_HHmmss_SSS"

    let ts = fmt.string(from: startedAt)
    let safeSession = sessionID.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression)
    return "\(ts)_\(String(format: "%06d", sequence))_\(safeSession)_\(purpose.rawValue).json"
  }
}

public struct WuhuLLMRequestLog: Sendable, Codable, Hashable {
  public var version: Int
  public var sessionID: String
  public var purpose: WuhuLLMRequestLogger.Purpose
  public var startedAt: Date
  public var finishedAt: Date
  public var request: WuhuLLMRequestSnapshot
  public var response: WuhuLLMResponseSnapshot?
  public var error: String?

  public init(
    version: Int,
    sessionID: String,
    purpose: WuhuLLMRequestLogger.Purpose,
    startedAt: Date,
    finishedAt: Date,
    request: WuhuLLMRequestSnapshot,
    response: WuhuLLMResponseSnapshot?,
    error: String?,
  ) {
    self.version = version
    self.sessionID = sessionID
    self.purpose = purpose
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.request = request
    self.response = response
    self.error = error
  }
}

public struct WuhuLLMRequestSnapshot: Sendable, Codable, Hashable {
  public var model: WuhuLLMModelSnapshot
  public var context: WuhuLLMContextSnapshot
  public var options: WuhuLLMOptionsSnapshot

  public init(model: WuhuLLMModelSnapshot, context: WuhuLLMContextSnapshot, options: WuhuLLMOptionsSnapshot) {
    self.model = model
    self.context = context
    self.options = options
  }
}

public struct WuhuLLMResponseSnapshot: Sendable, Codable, Hashable {
  public var assistant: WuhuAssistantMessage

  public init(assistant: WuhuAssistantMessage) {
    self.assistant = assistant
  }

  public init(from message: AssistantMessage) {
    assistant = .fromPi(message)
  }
}

public struct WuhuLLMModelSnapshot: Sendable, Codable, Hashable {
  public var provider: String
  public var id: String
  public var baseURL: String

  public init(provider: String, id: String, baseURL: String) {
    self.provider = provider
    self.id = id
    self.baseURL = baseURL
  }

  public init(from model: Model) {
    provider = model.provider.rawValue
    id = model.id
    baseURL = model.baseURL.absoluteString
  }
}

public struct WuhuLLMContextSnapshot: Sendable, Codable, Hashable {
  public var systemPrompt: String?
  public var messages: [WuhuPersistedMessage]
  public var tools: [WuhuLLMToolSnapshot]?

  public init(systemPrompt: String?, messages: [WuhuPersistedMessage], tools: [WuhuLLMToolSnapshot]?) {
    self.systemPrompt = systemPrompt
    self.messages = messages
    self.tools = tools
  }

  public init(from context: Context) {
    systemPrompt = context.systemPrompt
    messages = context.messages.map(WuhuPersistedMessage.fromPi)
    tools = context.tools?.map(WuhuLLMToolSnapshot.init(from:))
  }
}

public struct WuhuLLMToolSnapshot: Sendable, Codable, Hashable {
  public var name: String
  public var description: String
  public var parameters: JSONValue

  public init(name: String, description: String, parameters: JSONValue) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }

  public init(from tool: Tool) {
    name = tool.name
    description = tool.description
    parameters = tool.parameters
  }
}

public struct WuhuLLMOptionsSnapshot: Sendable, Codable, Hashable {
  public var temperature: Double?
  public var maxTokens: Int?
  public var sessionId: String?
  public var reasoningEffort: ReasoningEffort?
  public var headerKeys: [String]

  public init(
    temperature: Double?,
    maxTokens: Int?,
    sessionId: String?,
    reasoningEffort: ReasoningEffort?,
    headerKeys: [String],
  ) {
    self.temperature = temperature
    self.maxTokens = maxTokens
    self.sessionId = sessionId
    self.reasoningEffort = reasoningEffort
    self.headerKeys = headerKeys
  }

  public init(from options: RequestOptions) {
    temperature = options.temperature
    maxTokens = options.maxTokens
    sessionId = options.sessionId
    reasoningEffort = options.reasoningEffort
    headerKeys = options.headers.keys.sorted()
  }
}
