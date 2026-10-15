#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import SessionDomain
import SessionTools
import struct SessionToolsTestSupport.ScriptOwnerContract
import SpaceCore
import Testing
@testable import WorkerOwner
import WorkerProtocol
import struct WuhuAI.ToolCall

@Suite(.timeLimit(.minutes(1))) struct ToolOwnerRoundTripTests {
  let model = ModelSpecifier(provider: "offline", model: "small", effort: "none")

  @Test func fullRootRunsReusableOwnerContract() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "owner", kind: .agent, createdBy: "owner", model: model)
    try await withOwnerRPC(owner: InProcessToolOwnerClient(space: space)) { _, remote in
      let contract = ScriptOwnerContract(owner: remote, session: session)
      try await contract.guardedFilesAndFrozenModules()
      try await contract.typedDataAndQueryStream()
      try await contract.persistentToolReceipts()
    }
  }

  @Test func remoteScriptWritesThroughParentAndReadsItsResult() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "script", kind: .agent, createdBy: "owner", model: model)
    try await withOwnerRPC(owner: InProcessToolOwnerClient(space: space)) { _, remote in
      let scripts = Scripts(owner: remote)
      let tools = ToolExecutor(owner: remote, scripts: scripts)
      let call = ToolCall(id: "worker-script", name: "run_script", arguments: .object(["source": "import { writeText, readText } from 'wuhu:space'; await writeText('/rpc.txt', 'from worker', {ifMatch:null}); result((await readText('/rpc.txt')).content);", "timeout_seconds": 10, "on_timeout": "kill"]))
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripts.run() }
        defer { group.cancelAll() }
        let answer = try await tools.execute(session: session, call: call, state: .init())
        guard case let .script(result) = answer else { Issue.record("Script did not return a result: \(answer)"); return }
        #expect(result.output.contains("from worker"))
      }
      #expect(try await space.fs(.shared).read("/rpc.txt").1 == Data("from worker".utf8))
    }
  }

  @Test func identityBytesAndProtectedValuesStayOnSeparateLegs() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "identity", kind: .agent, createdBy: "owner", model: model)
    let owner = InProcessToolOwnerClient(space: space, identityFetch: { request, caller, protect in
      #expect(caller == session)
      #expect(request.url == URL(string: "https://identity.test/upload"))
      #expect(request.headers["X-Fixture"] == "header")
      let text = try await request.body?.text()
      #expect(text == "request-body")
      protect("fixture-secret")
      return .text("reply fixture-secret", status: .created)
    })
    try await withOwnerRPC(owner: owner) { _, remote in
      let reply = await remote.identityRequest(Request(url: URL(string: "https://identity.test/upload")!, method: .post, headers: RequestHeaders(values: ["X-Fixture": "header"]), body: .string("request-body")), session: session)
      #expect(reply.protectedValues == ["fixture-secret"])
      let response = try reply.response.get()
      #expect(response.status == .created)
      #expect(try await response.body.text() == "reply fixture-secret")
    }
  }

  @Test func identityFailureRetainsMaskingValuesAndTypedError() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "failure", kind: .agent, createdBy: "owner", model: model)
    let owner = InProcessToolOwnerClient(space: space, identityFetch: { _, _, protect in
      protect("fixture-secret")
      throw ScriptIdentityUnavailable(message: "fixture-secret refused")
    })
    try await withOwnerRPC(owner: owner) { _, remote in
      let reply = await remote.identityRequest(Request(url: URL(string: "https://identity.test/")!), session: session)
      #expect(reply.protectedValues == ["fixture-secret"])
      do { _ = try reply.response.get(); Issue.record("Identity failure was accepted") }
      catch let error as ScriptIdentityUnavailable { #expect(error.message == "fixture-secret refused") }
    }
  }

  @Test func toolStateSnapshotIncludesTransientHandlers() throws {
    let state = ToolExecutionState(handlerSubscriptions: [.init("handler")])
    let snapshot = try ownerDecode(ToolStateSnapshot.self, ownerEncode(ToolStateSnapshot(state)))
    #expect(snapshot.value == state)
  }

  @Test func truncatedRecordStreamFailsInsteadOfSilentlyCompleting() async throws {
    let reader = OwnerRecordReader<Int>(.string(""))
    do { _ = try await reader.next(); Issue.record("Truncated stream was accepted") }
    catch let error as WorkerProtocolError { #expect(error.code == .unavailable) }
  }
}
