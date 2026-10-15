#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineChannel
import MachineContract
import SessionDomain
import SessionTools
import SpaceCore
import SpaceTools
import Synchronization
import Testing
@testable import WorkerOwner

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

private final class FixtureFrames: FrameTransport {
  let inbound: AsyncStream<[UInt8]>
  let sent = Mutex<[[UInt8]]>([])
  let closed = Mutex(false)
  init() { inbound = AsyncStream { $0.yield([1, 0, 2]); $0.yield([3, 4]); $0.finish() } }
  func send(_ frame: [UInt8]) async throws { sent.withLock { $0.append(frame) } }
  func close() { closed.withLock { $0 = true } }
}
