#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ExecutionOwner
import InferenceKit
import Scratch
import SessionDomain
import SpaceCore
import Synchronization
import Testing
@testable import WorkerOwner
import WuhuAI

@Test func metricsAndTraceBytesArePublishedByParent() async throws {
  let space = try Space.inMemory()
  let directory = try ScratchFolder("worker-traces")
  let received = Mutex<[InferenceMetric]>([])
  let owner = InProcessExecutionOwnerClient(space: space, metrics: .init { metric in received.withLock { $0.append(metric) } }, attemptLog: .init(directory: directory.url))
  try await withOwnerRPC(owner: owner) { _, remote in
    let id = UUID()
    let trace = try await remote.openAttemptTrace(id)
    let data = Data(repeating: 65, count: 2 << 20)
    await trace.append(data)
    await trace.append(Data("last".utf8))
    await remote.closeAttemptTrace(id)
    #expect(try Data(contentsOf: directory.url.appending(path: id.uuidString.lowercased() + ".log")) == data + Data("last".utf8))
    let metric = InferenceMetric(timestamp: Date(timeIntervalSince1970: 10), session: .init(rawValue: "fixture"), provider: "offline", model: "small", servedModel: "served", effort: "none", outcome: .cancelled, durationMs: 120, usage: .init(inputTokens: 10, outputTokens: 5, totalTokens: 15))
    await remote.recordMetric(metric)
    #expect(received.withLock { $0 } == [metric])
  }
}

@Test func inferenceReadinessPreservesTypedFailure() async throws {
  let space = try Space.inMemory()
  let owner = InProcessExecutionOwnerClient(space: space)
  _ = try await withOwnerRPC(owner: owner) { _, remote in
    await #expect(throws: InferenceError.invalidInput(status: 422, body: "OIDC authentication is not configured on this server.")) {
      try await remote.inferenceReadiness(audience: URL(string: "https://fixture.invalid")!)
    }
  }
}
