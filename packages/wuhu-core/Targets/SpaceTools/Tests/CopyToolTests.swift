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
func copySeam(_ asked: Asked = Asked(), _ answer: @escaping @Sendable (CopySource, CopyTarget) async throws -> CopyReceipt) -> MachineSeam {
  MachineSeam(
    vfs: { _, _ in .error(error: .init(code: .io, message: "copy only")) },
    search: { _, _ in throw CancellationError() },
    copy: { source, target in
      asked.sources.withLock { $0.append(source) }
      return try await answer(source, target)
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
    let asked = Asked()
    let context = try context(copySeam(asked) { _, _ in throw refusal })
    let error = await failure("copy", ["from": "machines://mc_00000000/a", "to": "machines://mc_00000000/b", "overwrite": true], context)
    #expect(asked.sources.withLock { $0.count } == 1)
    #expect(code(error) == expected)
    if case .unsupported = refusal, case let .failed(_, message, _, _)? = error { #expect(message.contains(copyMachine.rawValue)) }
  }

  @Test(arguments: [(false, false), (false, true), (true, false)], [false, true])
  func lossWithoutOverwriteIsUnknownAndNeverRepeated(_ ends: (Bool, Bool), _ unknown: Bool) async throws {
    let (spaceSource, spaceTarget) = ends
    let asked = Asked()
    let context = try context(copySeam(asked) { _, _ in
      if unknown { throw MachineFileFailure.outcomeUnknown }
      throw MachineFileFailure.rangeLost(offset: 0)
    })
    if spaceSource { _ = try await seedFile("/source", "source", context) }
    let error = await failure("copy", [
      "from": .string(spaceSource ? "/source" : "machines://mc_00000000/source"),
      "to": .string(spaceTarget ? "/target" : "machines://mc_00000000/target"),
    ], context)
    #expect(asked.sources.withLock { $0.count } == 1)
    #expect(code(error) == .unavailable)
    if case let .failed(_, message, _, _)? = error {
      #expect(message.hasPrefix("outcomeUnknown:"))
      #expect(message.contains("read the path"))
    }
    if spaceTarget { #expect(code(await failure("read", ["path": "/target"], context)) == .notFound) }
  }

  @Test(arguments: [false, true], [false, true])
  func overwriteRestartsTheWholeCopyOnceIncludingSpaceLanding(_ spaceTarget: Bool, _ unknown: Bool) async throws {
    let asked = Asked()
    let attempts = Mutex(0)
    let context = try context(copySeam(asked) { source, target in
      #expect(source == .machine(copyMachine, path: "/source"))
      let attempt = attempts.withLock { $0 += 1; return $0 }
      if attempt == 1 {
        if unknown { throw MachineFileFailure.outcomeUnknown }
        throw MachineFileFailure.rangeLost(offset: 128)
      }
      #expect(attempt == 2)
      #expect(target == (spaceTarget ? .caller(limit: 64 << 20) : .machine(copyMachine, path: "/target", replace: true)))
      return CopyReceipt(bytes: 3, sha256: zeroHash, landing: spaceTarget ? .caller(Array("new".utf8)) : .machine(token: "new"))
    })
    let output = try await run("copy", ["from": "machines://mc_00000000/source", "to": .string(spaceTarget ? "/target" : "machines://mc_00000000/target"), "overwrite": true], context, as: CopyOutput.self)
    #expect(output.bytes == 3)
    #expect(asked.sources.withLock { $0.count } == 2)
    if spaceTarget { #expect(try await run("read", ["path": "/target"], context).object?["content"] == "new") }
  }

  @Test(arguments: [false, true]) func overwriteRematerializesTheSpaceSourceAfterLoss(_ unknown: Bool) async throws {
    let plain = try makeContext()
    _ = try await seedFile("/source", "old", plain)
    let asked = Asked()
    let seam = copySeam(asked) { source, _ in
      if source == .bytes(Array("old".utf8)) {
        _ = try await seedFile("/source", "new", plain)
        if unknown { throw MachineFileFailure.outcomeUnknown }
        throw MachineFileFailure.rangeLost(offset: 3)
      }
      #expect(source == .bytes(Array("new".utf8)))
      return CopyReceipt(bytes: 3, sha256: zeroHash, landing: .machine(token: "new"))
    }
    let context = SpaceToolContext(space: plain.space, machines: seam, principal: plain.principal)
    _ = try await run("copy", ["from": "/source", "to": "machines://mc_00000000/target", "overwrite": true], context)
    #expect(asked.sources.withLock { $0 } == [.bytes(Array("old".utf8)), .bytes(Array("new".utf8))])
  }

  @Test(arguments: [false, true], [false, true])
  func overwriteHasOneSharedLossBudget(_ firstUnknown: Bool, _ secondUnknown: Bool) async throws {
    let asked = Asked()
    let attempts = Mutex(0)
    let context = try context(copySeam(asked) { _, _ in
      let attempt = attempts.withLock { $0 += 1; return $0 }
      if attempt == 1 ? firstUnknown : secondUnknown { throw MachineFileFailure.outcomeUnknown }
      throw MachineFileFailure.rangeLost(offset: 3)
    })
    let error = await failure("copy", ["from": "machines://mc_00000000/source", "to": "machines://mc_00000000/target", "overwrite": true], context)
    #expect(asked.sources.withLock { $0.count } == 2)
    #expect(code(error) == .unavailable)
    if case let .failed(_, message, _, _)? = error { #expect(message.hasPrefix(secondUnknown ? "outcomeUnknown:" : "rangeLost:")) }
  }

  @Test(arguments: [false, true])
  func canceledKnownMachineCommitKeepsItsReceipt(_ overwrite: Bool) async throws {
    let entered = AsyncStream<Void>.makeStream()
    let paused = AsyncStream<Void>.makeStream()
    defer {
      entered.continuation.finish()
      paused.continuation.finish()
    }
    let asked = Asked()
    let context = try context(copySeam(asked) { _, target in
      #expect(target == .machine(copyMachine, path: "/target", replace: overwrite))
      entered.continuation.yield(())
      var iterator = paused.stream.makeAsyncIterator()
      _ = await iterator.next()
      #expect(Task.isCancelled)
      return CopyReceipt(bytes: 4, sha256: zeroHash, landing: .machine(token: "committed-token"))
    })
    let output = try await withThrowingTaskGroup(of: CopyOutput.self) { group in
      group.addTask {
        try await run("copy", ["from": "machines://mc_00000000/source", "to": "machines://mc_00000000/target", "overwrite": .bool(overwrite)], context, as: CopyOutput.self)
      }
      for await _ in entered.stream {
        group.cancelAll()
        break
      }
      return try #require(try await group.next())
    }
    #expect(output.bytes == 4)
    #expect(output.sha256 == zeroHash)
    #expect(output.token == "committed-token")
    #expect(asked.sources.withLock { $0.count } == 1)
  }

  @Test func canceledLateSuccessCannotWriteCollectedBytesIntoTheSpace() async throws {
    let entered = AsyncStream<Void>.makeStream()
    let paused = AsyncStream<Void>.makeStream()
    defer {
      entered.continuation.finish()
      paused.continuation.finish()
    }
    let context = try context(copySeam { _, _ in
      entered.continuation.yield(())
      var iterator = paused.stream.makeAsyncIterator()
      _ = await iterator.next()
      return CopyReceipt(bytes: 4, sha256: zeroHash, landing: .caller(Array("late".utf8)))
    })
    await withTaskGroup(of: ToolRunError?.self) { group in
      group.addTask { await failure("copy", ["from": "machines://mc_00000000/source", "to": "/target", "overwrite": true], context) }
      for await _ in entered.stream {
        group.cancelAll()
        break
      }
      #expect(await group.next() != nil)
    }
    #expect(code(await failure("read", ["path": "/target"], context)) == .notFound)
  }
}
