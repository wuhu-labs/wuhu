import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing
import struct WuhuAI.ToolArguments

@Suite struct ReceiptTests {
  @Test func spaceWriteCrashRetryReturnsTheRecordedOutcome() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)

      _ = try await space.fs(.shared).write("/a.txt", Data("v1".utf8), ifMatch: nil)
      _ = try await world.run("read", .object(["path": "/a.txt"]))
      guard case let .write(first) = try await world.run(
        "write", .object(["path": "/a.txt", "content": "v2"]), id: "tc-write",
      ) else { throw Mismatch("write failed") }

      // The effect and its receipt committed atomically, so there is no
      // window in which the write happened without the receipt.
      #expect(try await space.sessions.receipt(session, toolCallID: .init("tc-write")) == .write(first))

      // Crash-retry: the kernel never committed the result, so the retry
      // still carries the pre-write fileAccessLog — without the receipt this
      // would be a false stale failure.
      let retried = try await world.retry("write", .object(["path": "/a.txt", "content": "v2"]), id: "tc-write")
      #expect(retried == .write(first))
      #expect(try await space.readTextForTest("/a.txt") == "v2")
    }
  }

  @Test func spaceEditCrashRetryReturnsTheRecordedOutcome() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)

      _ = try await space.fs(.shared).write("/a.txt", Data("hello world".utf8), ifMatch: nil)
      _ = try await world.run("read", .object(["path": "/a.txt"]))
      let edit = ToolArguments.object(["path": "/a.txt", "edits": .array([.object(["old": "world", "new": "wuhu"])])])
      guard case let .edit(first) = try await world.run("edit", edit, id: "tc-edit") else {
        throw Mismatch("edit failed")
      }

      let retried = try await world.retry("edit", edit, id: "tc-edit")
      #expect(retried == .edit(first))
      #expect(try await space.readTextForTest("/a.txt") == "hello wuhu", "the retry must not re-apply the edit")
    }
  }

  @Test func machineWriteCrashRetryReturnsTheRecordedOutcome() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      let machineFS = FakeMachineFS()
      machineFS.put("/home/dev/a.txt", "v1", mtime: 100)
      var world = ToolWorld(
        executor: ToolExecutor(space: space, machines: machineFS.seam),
        session: session,
      )

      let path = JSONValue.string("machines://\(machineA.rawValue)/home/dev/a.txt")
      _ = try await world.run("read", .object(["path": path]))
      guard case let .write(first) = try await world.run(
        "write", .object(["path": path, "content": "v2"]), id: "tc-mwrite",
      ) else { throw Mismatch("machine write failed") }

      let retried = try await world.retry("write", .object(["path": path, "content": "v2"]), id: "tc-mwrite")
      #expect(retried == .write(first), "the retry must return the recorded success, not a stale failure")
    }
  }

  @Test func createSessionAgainstAForeignReceiptFailsTypedInsteadOfCrashing() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      var world = ToolWorld(
        executor: ToolExecutor(space: space, resolveModelExecutor: { provider, model, effort in
          .kernel(ModelSpecifier(provider: provider, model: model, effort: effort ?? "high"))
        }),
        session: session,
      )

      let foreign = ToolResultPayload.write(.init(path: "/a.txt", revision: .journal(1)))
      try await space.sessions.recordReceipt(session, toolCallID: .init("call_0"), payload: foreign)

      let message = try failureMessage(try await world.run("create_session", .object([
        "kind": "agent", "title": .string("helper"), "provider": .string("deepseek"), "model": .string("deepseek-v4-pro"),
      ]), id: "call_0"))
      #expect(message.contains("create_session"))
      #expect(message.contains("call_0"))

      #expect(try await space.sessions.receipt(session, toolCallID: .init("call_0")) == foreign)
      let helpers = try await space.query("SELECT id FROM sessions WHERE title = 'helper'", as: .shared(.anonymous))
      #expect(helpers.rows.isEmpty)

      guard case .createSession = try await world.run("create_session", .object([
        "kind": "agent", "title": .string("helper"), "provider": .string("deepseek"), "model": .string("deepseek-v4-pro"),
      ]), id: "call_1") else { throw Mismatch("a fresh tool call id must still create") }
    }
  }

  @Test func readIsIdempotentAndRecordsNoReceipt() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)

      _ = try await space.fs(.shared).write("/a.txt", Data("v1".utf8), ifMatch: nil)
      let first = try await world.run("read", .object(["path": "/a.txt"]), id: "tc-read")
      let again = try await world.retry("read", .object(["path": "/a.txt"]), id: "tc-read")
      #expect(first == again)
      #expect(try await space.sessions.receipt(session, toolCallID: .init("tc-read")) == nil)
    }
  }
}
