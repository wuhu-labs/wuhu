#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import MachineChannel
import MachineContract
import SessionDomain
import SessionTools
import SpaceCore
import SpaceTools
import Synchronization
import Testing
@testable import WorkerOwner
import struct WuhuAI.ToolCall

@Suite(.timeLimit(.minutes(1))) struct MachineOwnerTests {
  @Test func machineFramesAndExecClaimsKeepParentAuthorityAndBoundaries() async throws {
    let space = try Space.inMemory()
    let machine = try await space.addMachine(name: "fixture")
    let session = try await space.sessions.createSession(group: .shared, title: "machine", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let transport = FixtureFrames()
    let killed = Mutex<[ExecID]>([])
    let backend = ExecBackend(claim: { machine, caller, call in
      try await space.claimExec(machine: machine, caller: caller.rawValue, toolCallID: call)
    }, connect: { _ in transport }, status: { try await space.execRecord($0) }, mintScript: { machine, caller, script in
      try await space.mintScriptExec(machine: machine, session: caller.rawValue, script: script)
    }, kill: { id in killed.withLock { $0.append(id) } })
    let files = MachineSeam(vfs: { _, _ in .file(token: "version", data: .init([1, 2, 3])) }, search: { _, _ in .paths(paths: ["/fixture"], cursor: "next") }, attached: { [machine.id] })
    let owner = InProcessToolOwnerClient(space: space, scriptMachines: .init(files: files, exec: backend))
    try await withOwnerRPC(owner: owner) { _, remote in
      let access = try #require(remote.scriptMachines(for: session))
      #expect(await access.files.attached() == [machine.id])
      #expect(try await access.files.vfs(machine.id, .read(path: "/file")) == .file(token: "version", data: .init([1, 2, 3])))
      #expect(try await access.files.search(machine.id, .find(glob: "*", path: nil, matchLimit: nil, entryLimit: nil, step: nil)) == .paths(paths: ["/fixture"], cursor: "next"))
      let first = try await access.exec.claim(machine.id, session, .init("call"))
      let again = try await access.exec.claim(machine.id, session, .init("call"))
      #expect(!first.rejoined && again.rejoined && again.record.id == first.record.id)
      #expect(try await access.exec.status(first.record.id) == first.record)
      let connection = try await access.exec.connect(first.record.id)
      try await connection.send([9, 0, 8])
      #expect(transport.sent.withLock { $0 } == [[9, 0, 8]])
      var frames: [[UInt8]] = []
      for await frame in connection.inbound { frames.append(frame) }
      #expect(frames == [[1, 0, 2], [3, 4]])
      try await access.exec.kill(first.record.id)
      #expect(killed.withLock { $0 } == [first.record.id])
      let script = try await access.exec.mintScript(machine.id, session, "script")
      #expect(script.caller == session.rawValue)
      #expect(try await space.takeScriptExecOwners().first?.script == "script")
    }
    #expect(transport.closed.withLock { $0 })
  }
}

extension MachineOwnerTests {
  // Under an execution worker a tool's machine calls run in the parent's RPC task, so the parent owner must bind
  // the calling session itself; the worker's task-locals never cross the RPC.
  @Test func workerToolCallsReachTheMachineAttributedToTheirSession() async throws {
    let space = try Space.inMemory()
    let machine = try await space.addMachine(name: "fixture")
    let session = try await space.sessions.createSession(group: .shared, title: "machine", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let callers = Mutex<[SessionID?]>([])
    let files = MachineSeam(vfs: { _, op in
      callers.withLock { $0.append(MachineSeam.caller) }
      switch op {
      case .stat(path: "/notes.txt"): return .entry(entry: .init(name: "notes.txt", kind: .file, size: 5, token: "1", mtime: 1))
      case .stat: return .error(error: MachineError(code: .notFound, message: "missing"))
      case .write: return .written(token: "2")
      case .read: return .file(token: "1", data: .init(Array("hello".utf8)))
      default: return .ok
      }
    }, search: { _, _ in
      callers.withLock { $0.append(MachineSeam.caller) }
      return .paths(paths: ["/notes.txt"], cursor: nil)
    }, attached: { [machine.id] })
    let owner = InProcessToolOwnerClient(space: space, machines: files)
    try await withOwnerRPC(owner: owner) { _, remote in
      let tools = ToolExecutor(owner: remote, scripts: Scripts(owner: remote))
      let read = ToolCall(id: "worker-read", name: "read", arguments: .object(["path": .string("machines://\(machine.id.rawValue)/notes.txt")]))
      let find = ToolCall(id: "worker-find", name: "find", arguments: .object(["glob": "*", "path": .string("machines://\(machine.id.rawValue)/")]))
      for call in [read, find] {
        let payload = try await tools.execute(session: session, call: call, state: .init())
        if case let .failure(failure) = payload { Issue.record("\(call.name) failed: \(failure.message)") }
      }
      let before = callers.withLock { $0.count }
      // Generated images and capability inputs touch the machine from the parent owner too.
      _ = try await remote.placeImage(Data([0x89, 0x50, 0x4E, 0x47]), at: .machine(machine.id, "/out/image.png"), session: session, call: nil, state: nil)
      let placed = callers.withLock { $0.count }
      #expect(placed > before)
      #expect(try await remote.capabilityInput("machines://\(machine.id.rawValue)/notes.txt", as: session, limit: 1024) == Data("hello".utf8))
      #expect(callers.withLock { $0.count } > placed)
    }
    let seen = callers.withLock { $0 }
    #expect(seen.count >= 6); #expect(seen.allSatisfy { $0 == session })
  }
}

private final class FixtureFrames: FrameTransport {
  let inbound: AsyncStream<[UInt8]>
  let sent = Mutex<[[UInt8]]>([])
  let closed = Mutex(false)
  init() { inbound = AsyncStream { $0.yield([1, 0, 2]); $0.yield([3, 4]); $0.finish() } }
  func send(_ frame: [UInt8]) async throws { sent.withLock { $0.append(frame) } }
  func close() { closed.withLock { $0 = true } }
}
