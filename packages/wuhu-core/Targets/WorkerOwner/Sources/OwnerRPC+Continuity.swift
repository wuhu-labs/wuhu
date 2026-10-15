#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import struct Fetch.Body
import Logging
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError
import struct WorkerProtocol.WorkerReply

extension OwnerRPC {
  func retainedCall<Result: Decodable & Sendable>(_ call: WorkerCall, consume: Bool = true) async throws -> Result {
    do {
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        let reply: WorkerReply = try await recovering {
          let input = WorkerCall(id: call.id, operation: "owner.input", payload: .string(call.operation), traceContext: call.traceContext, receipt: call.receipt)
          try await client.upload(input, body: .json(call.payload))
          let output = WorkerCall(id: call.id, operation: "owner.output", payload: .string(call.operation), traceContext: call.traceContext, receipt: call.receipt)
          return try await client.stream(output).json(WorkerReply.self, upTo: 64 << 20)
        }
        guard reply.abi == call.abi, reply.id == call.id, (reply.result != nil) != (reply.error != nil) else {
          throw WorkerProtocolError(.invalidMessage, message: "Invalid retained owner reply correlation")
        }
        let outcome = Swift.Result<Result, any Error> {
          if let error = reply.error {
            if error.code == .cancelled { throw CancellationError() }
            throw error
          }
          let envelope = try ownerDecode(OwnerEnvelope.self, reply.result!)
          if let fault = envelope.fault { throw try fault.error() }
          return try ownerDecode(Result.self, envelope.value)
        }
        if consume || outcome.isFailure { try await acknowledge(call) }
        return try outcome.get()
      } onCancel: {
        Task { await cancel(call.id) }
      }
    } catch {
      if let failure = error as? WorkerProtocolError, failure.code == .unknownOutcome { throw failure }
      let cleanup = Task {
        try await recovering {
          _ = try await client.call(WorkerCall(operation: "owner.cancel", payload: ownerEncode(StreamRequest(id: call.id))))
        }
        try await acknowledge(call)
      }
      _ = try? await cleanup.value
      throw error
    }
  }

  func acknowledge(_ call: WorkerCall) async throws {
    try await recovering {
      _ = try await client.call(WorkerCall(operation: "owner.ack", payload: ownerEncode(call.receipt!)))
      await client.consumed(call)
    }
  }

  func recovering<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
    var delay = Duration.milliseconds(100)
    while true {
      try Task.checkCancellation()
      do { return try await operation() }
      catch let error as WorkerProtocolError where error.code == .unavailable {
        try await reconnect(delay: delay)
        delay = min(delay * 2, .seconds(5))
      }
    }
  }

  func reconnect(delay initial: Duration = .milliseconds(100)) async throws {
    @Dependency(\.continuousClock) var clock
    var delay = initial
    while true {
      guard await !client.isClosed else { throw WorkerProtocolError(.unavailable, message: "Worker connection is permanently closed") }
      Logger(label: "wuhu.owner-reconnect").warning("Owner transport unavailable; retrying", metadata: ["delay": "\(delay)"])
      try await clock.sleep(for: delay)
      do { try await client.reconnect(); return }
      catch let error as WorkerProtocolError where error.code == .unavailable {
        guard await !client.isClosed else { throw error }
        delay = min(delay * 2, .seconds(5))
        continue
      }
    }
  }
}

private extension Result {
  var isFailure: Bool { if case .failure = self { true } else { false } }
}
