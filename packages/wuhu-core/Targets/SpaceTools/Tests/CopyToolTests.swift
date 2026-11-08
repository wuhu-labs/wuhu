import ControlledTime
import DeterministicDependencies
import Foundation
import JSONValue
import MachineContract
import SpaceContract
import SpaceCore
import SpaceTools
import Synchronization
import Testing

final class Asked: Sendable {
  let sources = Mutex<[CopySource]>([])
}

/// A seam whose only working call is `copy`, answered by `answer`; every copy it was asked for is in `asked`.
func copySeam(_ asked: Asked = Asked(), _ answer: @escaping @Sendable (CopySource, CopyTarget) throws -> CopyReceipt) -> MachineSeam {
  MachineSeam(
    vfs: { _, _ in .error(error: .init(code: .io, message: "copy only")) },
    search: { _, _ in throw CancellationError() },
    copy: { source, target in
      asked.sources.withLock { $0.append(source) }
      return try answer(source, target)
    },
    attached: { [] },
  )
}

let copyMachine = MachineID(rawValue: "mc_00000000")
let zeroHash = String(repeating: "0", count: 64)

@Suite(.deterministicDependencies(clock: VirtualClock())) struct CopyToolTests {
  func context(_ seam: MachineSeam) throws -> SpaceToolContext {
    let plain = try makeContext()
    return SpaceToolContext(space: plain.space, machines: seam, principal: plain.principal)
  }

  func code(_ error: ToolRunError?) -> ErrorCode? {
    guard case let .failed(code, _, _, _)? = error else { return nil }
    return code
  }

  @Test func aSpaceFileGoesToAMachineAsItsBytes() async throws {
    let asked = Asked()
    let context = try context(copySeam(asked) { source, target in
      #expect(target == .machine(copyMachine, path: "/srv/a.md", replace: false))
      return CopyReceipt(bytes: 5, sha256: zeroHash, landing: .machine(token: "machine-token"))
    })
    _ = try await seedFile("/a.md", "hello", context)
    let output = try await run("copy", ["from": "/a.md", "to": "machines://mc_00000000/srv/a.md"], context, as: CopyOutput.self)
    #expect([output.bytes.description, output.sha256, output.token] == ["5", zeroHash, "machine-token"])
    #expect(asked.sources.withLock { $0 } == [.bytes(Array("hello".utf8))])
  }

  @Test func aMachineFileLandsInTheSpaceCreatedThenOnlyReplacedWithOverwrite() async throws {
    let content = Mutex("first")
    let context = try context(copySeam { source, target in
      #expect(source == .machine(copyMachine, path: "/log.txt"))
      #expect(target == .caller(limit: 64 << 20))
      let bytes = Array(content.withLock { $0 }.utf8)
      return CopyReceipt(bytes: bytes.count, sha256: zeroHash, landing: .caller(bytes))
    })
    let from: JSONValue = "machines://mc_00000000/log.txt"
    _ = try await run("copy", ["from": from, "to": "/logs/log.txt"], context, as: CopyOutput.self)
    content.withLock { $0 = "second" }
    let refused = await failure("copy", ["from": from, "to": "/logs/log.txt"], context)
    #expect(code(refused) == .exists)
    #expect(try await run("read", ["path": "/logs/log.txt"], context).object?["content"] == "first")
    let replaced = try await run("copy", ["from": from, "to": "/logs/log.txt", "overwrite": true], context, as: CopyOutput.self)
    #expect(replaced.bytes == 6)
    #expect(try await run("read", ["path": "/logs/log.txt"], context).object?["content"] == "second")
  }

  @Test func spaceToSpaceIsRefusedAndNeverAsksTheSeam() async throws {
    let asked = Asked()
    let context = try context(copySeam(asked) { _, _ in throw CopyRefusal.sourceChanged })
    _ = try await seedFile("/a.md", "hello", context)
    #expect(code(await failure("copy", ["from": "/a.md", "to": "/b.md"], context)) == .unsupported)
    #expect(asked.sources.withLock { $0 }.isEmpty)
  }

  @Test(arguments: [
    (CopyRefusal.sourceChanged, ErrorCode.sourceChanged),
    (.targetExists, .exists),
    (.sourceNotAFile, .invalidArgument),
    (.missing(.source), .notFound),
    (.unsupported(copyMachine), .unsupported),
  ])
  func eachRefusalAnswersItsCode(_ refusal: CopyRefusal, _ expected: ErrorCode) async throws {
    let context = try context(copySeam { _, _ in throw refusal })
    let error = await failure("copy", ["from": "machines://mc_00000000/a", "to": "machines://mc_00000000/b"], context)
    #expect(code(error) == expected)
    if case .unsupported = refusal, case let .failed(_, message, _, _)? = error { #expect(message.contains(copyMachine.rawValue)) }
  }
}
