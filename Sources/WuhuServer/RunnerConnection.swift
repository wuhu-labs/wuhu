import Foundation
import Logging
import PiAgent
import PiAI
import WSCore
import WuhuAPI

final actor RunnerConnection {
  let runnerName: String

  private let logger: Logger
  private var outbound: WebSocketOutboundWriter

  private var pending: [String: CheckedContinuation<WuhuRunnerMessage, any Error>] = [:]
  private var isClosed: Bool = false

  init(
    runnerName: String,
    outbound: WebSocketOutboundWriter,
    logger: Logger,
  ) {
    self.runnerName = runnerName
    self.outbound = outbound
    self.logger = logger
  }

  func close(_ error: any Error = PiAIError.decoding("Runner connection closed")) {
    guard !isClosed else { return }
    isClosed = true
    failAllPending(error)
  }

  func resolveEnvironment(name: String) async throws -> WuhuEnvironment {
    let id = UUID().uuidString
    let response = try await requestResponse(
      requestId: id,
      message: .resolveEnvironmentRequest(id: id, name: name),
    )
    guard case let .resolveEnvironmentResponse(_, environment, error) = response else {
      throw PiAIError.decoding("Unexpected response")
    }
    if let environment { return environment }
    throw PiAIError.unsupported(error ?? "Unknown environment")
  }

  func registerSession(sessionID: String, environment: WuhuEnvironment) async throws {
    try await send(.registerSession(sessionID: sessionID, environment: environment))
  }

  func executeTool(
    sessionID: String,
    toolCallId: String,
    toolName: String,
    args: JSONValue,
  ) async throws -> AgentToolResult {
    let id = UUID().uuidString
    let response = try await requestResponse(
      requestId: id,
      message: .toolRequest(id: id, sessionID: sessionID, toolCallId: toolCallId, toolName: toolName, args: args),
    )
    guard case let .toolResponse(_, _, _, resultValue, isError, errorMessage) = response else {
      throw PiAIError.decoding("Unexpected response")
    }
    if isError {
      throw PiAIError.unsupported(errorMessage ?? "Tool execution failed")
    }
    let result = resultValue ?? .init(content: [.text(text: "(no output)", signature: nil)], details: .object([:]))
    return AgentToolResult(
      content: result.content.map { $0.toPi() },
      details: result.details,
    )
  }

  func handleIncoming(_ message: WuhuRunnerMessage) {
    switch message {
    case .hello, .registerSession, .resolveEnvironmentRequest, .toolRequest:
      return
    case let .resolveEnvironmentResponse(id, _, _),
         let .toolResponse(id, _, _, _, _, _):
      if let cont = pending.removeValue(forKey: id) {
        cont.resume(returning: message)
      }
    }
  }

  private func requestResponse(
    requestId: String,
    message: WuhuRunnerMessage,
  ) async throws -> WuhuRunnerMessage {
    try await withCheckedThrowingContinuation { continuation in
      if isClosed {
        continuation.resume(throwing: PiAIError.unsupported("Runner '\(runnerName)' is disconnected"))
        return
      }
      pending[requestId] = continuation
      Task {
        do {
          try await self.send(message)
        } catch {
          if let cont = pending.removeValue(forKey: requestId) {
            cont.resume(throwing: error)
          }
        }
      }
    }
  }

  private func send(_ message: WuhuRunnerMessage) async throws {
    let data = try WuhuJSON.encoder.encode(message)
    let text = String(decoding: data, as: UTF8.self)
    try await outbound.write(.text(text))
  }

  private func failAllPending(_ error: any Error) {
    for (_, cont) in pending {
      cont.resume(throwing: error)
    }
    pending.removeAll()
  }
}
