#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import ExecutionOwner
import Fetch
import ServerTelemetry
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ExecutionWorkerBootAdmissionTests {
  @Test func completeOwnershipNeverNarrowsLegacyOrUnknownWorkerEvidence() async throws {
    let space = try Space.inMemory()
    let known = UUID(), legacy = UUID()
    let manifest = ExecutionWorkerManifest(version: 1, space: "space", generation: UUID(), incarnation: known, processID: 123, birth: "fixture", credentials: .init(current: String(repeating: "a", count: 72)))
    try await space.sessions.beginWorkerOwnership(incarnation: known)
    let knownWorker = ExecutionWorkerBootFence.UnresolvedWorker(manifest: manifest, directory: "/private/known", reason: .unconfirmed)
    let unknownWorker = ExecutionWorkerBootFence.UnresolvedWorker(directory: "/private/unknown", reason: .corrupt)
    await #expect(throws: ExecutionWorkerBootRefusal.self) {
      try await ExecutionWorkerBootReconciliation.prepare(sessions: space.sessions) {
        .init(unresolved: [known, legacy], unresolvedWorkers: [knownWorker], credentials: .init())
      }
    }
    await #expect(throws: ExecutionWorkerBootRefusal.self) {
      try await ExecutionWorkerBootReconciliation.prepare(sessions: space.sessions) {
        .init(unresolved: [known], unresolvedWorkers: [knownWorker, unknownWorker], credentials: .init())
      }
    }
    let empty = try await ExecutionWorkerBootReconciliation.prepare(sessions: space.sessions) {
      .init(unresolved: [known], unresolvedWorkers: [knownWorker], credentials: .init())
    }
    #expect(empty.blockedSessions.isEmpty)
  }

  @Test func ownerAdmissionWaitsForEveryEntryAndRefusalIsAfterTheBatch() async throws {
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let gate = Task { for await _ in release.stream { break } }
    defer { entered.continuation.finish(); release.continuation.finish(); gate.cancel() }
    let processed = Mutex<[String]>([])
    let ownerAdmitted = Mutex(false)
    let incarnation = UUID()
    let manifest = ExecutionWorkerManifest(version: 1, space: "space", generation: UUID(), incarnation: incarnation, processID: 123, birth: "secret-bearer-as-untrusted-birth", credentials: .init(current: String(repeating: "a", count: 72)))
    let admission = Task {
      let result = try await ExecutionWorkerBootReconciliation.prepare {
        await ExecutionWorkerBootFence.reconcile(effects: .init(inventory: { .directories(["first", "second"]) }, read: { directory in
          if directory == "second" { entered.continuation.yield(()); await gate.value }
          processed.withLock { $0.append(directory) }
          return .manifest(manifest)
        }, process: { _ in .unverified }, terminate: { _, _ in .unconfirmed }, cleanup: { _ in Issue.record("Unverified runtime cannot be removed") }, report: { _ in }))
      }
      ownerAdmitted.withLock { $0 = true }
      return result
    }
    for await _ in entered.stream { break }
    #expect(processed.withLock { $0 } == ["first"])
    #expect(ownerAdmitted.withLock { !$0 })
    release.continuation.yield(())
    do { _ = try await admission.value; Issue.record("Unfenced worker admitted an owner") }
    catch let error as ExecutionWorkerBootRefusal {
      #expect(error.workers.count == 2)
      #expect(error.workers.map(\.directory) == ["first", "second"])
      let diagnostic = error.description
      #expect(diagnostic.contains("pid=123"))
      #expect(diagnostic.contains("runtime=first"), Comment(rawValue: diagnostic))
      #expect(diagnostic.contains("stop the matching worker"))
      #expect(!diagnostic.contains(manifest.birth))
      #expect(!diagnostic.contains(manifest.credentials.current))
    }
    #expect(processed.withLock { $0 } == ["first", "second"])
    #expect(ownerAdmitted.withLock { !$0 })
  }

  @Test func reconciliationTelemetryContainsOnlyTypedOutcomePlatformAndCount() throws {
    let spans = Mutex<[FinishedSpan]>([])
    ServerTracing.$emitter.withValue({ span in spans.withLock { $0.append(span) } }) {
      ExecutionWorkerBootReconciliation.report(.staleCredentialTerminated)
    }
    let span = try #require(spans.withLock { $0.first })
    #expect(span.name == .executionWorkerFence)
    #expect(span.attributes[.outcome] == "staleCredentialTerminated")
    #expect(span.attributes[.count] == "1")
    #expect(span.attributes.count == 3)
  }
}
