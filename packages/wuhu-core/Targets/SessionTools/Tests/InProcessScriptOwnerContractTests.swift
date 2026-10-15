#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import SessionDomain
@testable import SessionTools
import struct SessionToolsTestSupport.ScriptOwnerContract
import SpaceCore
import Testing

@Suite struct InProcessScriptOwnerContractTests {
  @Test func guardedFilesAndFrozenModules() async throws {
    try await withOwner { try await $0.guardedFilesAndFrozenModules() }
  }

  @Test func typedDataAndQueryStream() async throws {
    try await withOwner { try await $0.typedDataAndQueryStream() }
  }

  @Test func persistentToolReceipts() async throws {
    try await withOwner { try await $0.persistentToolReceipts() }
  }

  @Test func watchCancellationReleasesParentStream() async throws {
    let parent = AsyncStream<FSCommit>.makeStream()
    let parentEnded = Box(false)
    parent.continuation.onTermination = { _ in parentEnded.withLock { $0 = true } }
    let relay = parentWatchRelay(parent.stream, prefix: "")
    let entered = AsyncStream.makeStream(of: Void.self)
    let consumerEnded = Box(false)
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        entered.continuation.yield(())
        entered.continuation.finish()
        do { for try await _ in relay.events {} } catch {}
        consumerEnded.withLock { $0 = true }
      }
      for await _ in entered.stream {}
      group.cancelAll()
    }
    try await until("parent observation terminated") { parentEnded.value }
    await relay.pump.value
    #expect(parentEnded.value)
    #expect(consumerEnded.value)
    #expect(relay.pump.isCancelled)
  }
}

private func withOwner(_ body: (ScriptOwnerContract) async throws -> Void) async throws {
  try await withToolDeps { _ in
    let space = try Space.inMemory()
    let session = try await makeSession(space)
    try await body(.init(owner: InProcessToolOwnerClient(space: space), session: session))
  }
}

extension InProcessScriptOwnerContractTests {
  @Test func failedIdentityRequestKeepsProtectedValuesAcrossOwnerBoundary() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let owner: any WorkerOwnerClient = InProcessToolOwnerClient(space: space, identityFetch: { _, caller, protect in
        #expect(caller == session)
        protect("OWNER-TOKEN")
        throw ScriptIdentityUnavailable(message: "failed OWNER-TOKEN owner-token")
      })
      let scripts = Scripts(owner: owner)
      let tools = ToolExecutor(owner: owner, scripts: scripts)
      let execution = scripts.start("try { await fetch('https://identity.test', {identity:true}) } catch(e) { result(e.message) }", session: session, lifetime: .seconds(10), tools: tools)
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await scripts.run() }
        let answer = try? await execution.answer(within: .seconds(10), onTimeout: .kill)
        #expect(answer == .result("failed *** ***"))
        group.cancelAll()
      }
    }
  }

  @Test func interruptedExecKillsOnlyItsLiveClaimAndUsesRootMachineFacet() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "owner-box").id
      var backend = ScriptedExecMachine().backend(space)
      let killed = Box<[String]>([])
      backend.kill = { id in killed.withLock { $0.append(id.rawValue) } }
      let claim = try await backend.claim(machine, session, .init("interrupted"))
      let owner: any WorkerOwnerClient = InProcessToolOwnerClient(space: space, exec: backend, scriptMachines: .init(files: FakeMachineFS().seam, exec: backend))
      #expect(owner.scriptMachines(for: session) != nil)
      await owner.killInterruptedExec(session: session, toolCallID: .init("missing"))
      #expect(killed.value.isEmpty)
      await owner.killInterruptedExec(session: session, toolCallID: .init("interrupted"))
      #expect(killed.value == [claim.record.id.rawValue])
      try await space.finishExec(claim.record.id, .exited(code: 0))
      await owner.killInterruptedExec(session: session, toolCallID: .init("interrupted"))
      #expect(killed.value.count == 1)
    }
  }
}
