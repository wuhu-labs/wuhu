import Foundation
import Logging
import PiAI
import WSClient
import WSCore
import WuhuAPI

actor RunnerRegistry {
  private var connections: [String: RunnerConnection] = [:]

  func listRunnerNames() -> [String] {
    connections.keys.sorted()
  }

  func set(_ connection: RunnerConnection, for runnerName: String? = nil) {
    connections[runnerName ?? connection.runnerName] = connection
  }

  func remove(runnerName: String) {
    connections.removeValue(forKey: runnerName)
  }

  func get(runnerName: String) -> RunnerConnection? {
    connections[runnerName]
  }

  func connectToRunnerServer(runner: WuhuServerConfig.Runner, logger: Logger) async throws {
    let wsURL = wsURLFromAddress(runner.address, path: "/v2/runner/ws")

    let client = WebSocketClient(url: wsURL, logger: logger) { inbound, outbound, context in
      do {
        try await self.handleSocket(
          inbound: inbound,
          outbound: outbound,
          logger: context.logger,
          expectedRunnerName: runner.name,
        )
      } catch {
        context.logger.error(
          "Runner WebSocket connection failed",
          metadata: ["runner": "\(runner.name)", "error": "\(error)"],
        )
      }
    }

    try await client.run()
  }

  func acceptRunnerClient(
    inbound: WebSocketInboundStream,
    outbound: WebSocketOutboundWriter,
    logger: Logger,
  ) async throws {
    try await handleSocket(
      inbound: inbound,
      outbound: outbound,
      logger: logger,
      expectedRunnerName: nil,
    )
  }

  private func handleSocket(
    inbound: WebSocketInboundStream,
    outbound: WebSocketOutboundWriter,
    logger: Logger,
    expectedRunnerName: String?,
  ) async throws {
    var iterator = inbound.messages(maxSize: 16 * 1024 * 1024).makeAsyncIterator()

    guard let helloMessage = try await iterator.next() else {
      throw PiAIError.decoding("Runner WebSocket closed before hello")
    }
    guard case let .text(helloText) = helloMessage, let helloData = helloText.data(using: .utf8) else {
      throw PiAIError.decoding("Runner hello must be a text WebSocket message")
    }
    let hello = try WuhuJSON.decoder.decode(WuhuRunnerMessage.self, from: helloData)
    guard case let .hello(actualName, version) = hello else {
      throw PiAIError.decoding("First runner message must be hello")
    }
    guard version == 1 else {
      throw PiAIError.unsupported("Unsupported runner protocol version \(version)")
    }

    if let expectedRunnerName, expectedRunnerName != actualName {
      throw PiAIError.unsupported("Runner name mismatch (expected '\(expectedRunnerName)', got '\(actualName)')")
    }

    let registeredName = expectedRunnerName ?? actualName
    let connection = RunnerConnection(runnerName: registeredName, outbound: outbound, logger: logger)
    set(connection, for: registeredName)

    defer {
      remove(runnerName: registeredName)
      Task { await connection.close(PiAIError.decoding("Runner WebSocket closed")) }
    }

    while let message = try await iterator.next() {
      guard case let .text(text) = message else { continue }
      guard let data = text.data(using: .utf8) else { continue }
      do {
        let decoded = try WuhuJSON.decoder.decode(WuhuRunnerMessage.self, from: data)
        await connection.handleIncoming(decoded)
      } catch {
        logger.debug("Failed to decode runner message", metadata: ["runner": "\(registeredName)", "error": "\(error)"])
      }
    }
  }
}

private func wsURLFromAddress(_ address: String, path: String) -> String {
  if address.hasPrefix("ws://") || address.hasPrefix("wss://") {
    return address + path
  }
  return "ws://\(address)\(path)"
}
