#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
import Fetch
import GRDB
import MachineContract
import OperationProtocol
import OperationRuntime
import Scratch
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

extension MachineFileTransferTests {
  @Test(arguments: 0 ..< 12)
  func eightMiBWriteThroughTheRealConnectionLandsAndRetires(run: Int) async throws {
    let folder = try ScratchFolder("real-write-\(run)")
    let write = RealFileWrite(machine: b, target: folder.url.appending(path: "target"), bytes: writeBytes(seed: run))
    try await checkRealWrites([write], in: folder)
  }

  @Test(arguments: [false, true])
  func concurrentEightMiBWritesLandAndRetireOnTheSameOrDifferentBoxes(sameBox: Bool) async throws {
    let folder = try ScratchFolder("real-concurrent-write")
    let writes = [
      RealFileWrite(machine: a, target: folder.url.appending(path: "first"), bytes: writeBytes(seed: 17)),
      RealFileWrite(machine: sameBox ? a : b, target: folder.url.appending(path: "second"), bytes: writeBytes(seed: 29)),
    ]
    try await checkRealWrites(writes, in: folder)
  }

  private func writeBytes(seed: Int) -> Data {
    Data((0 ..< 8 * 1024 * 1024).map { UInt8(truncatingIfNeeded: ($0 &* 31) ^ ($0 >> 8) ^ ($0 >> 16) ^ seed) })
  }

  private func checkRealWrites(_ writes: [RealFileWrite], in folder: ScratchFolder) async throws {
    let machines = Dictionary(uniqueKeysWithValues: Set(writes.map(\.machine.rawValue)).map { ($0, fileOperationKinds()) })
    try await withMachines(machines) { transfer in
      let results = await withTaskGroup(of: (Int, Result<String, any Error>).self) { group in
        for (index, write) in writes.enumerated() {
          group.addTask {
            do {
              let token = try await MachineFileClient(space: transfer.space, machine: write.machine, caller: nil).write(write.target.path, data: write.bytes, ifMatch: nil)
              return (index, .success(token))
            } catch { return (index, .failure(error)) }
          }
        }
        var results: [Int: Result<String, any Error>] = [:]
        for await (index, result) in group { results[index] = result }
        return results
      }
      #expect(results.count == writes.count)
      var failed = false
      for (index, write) in writes.enumerated() {
        switch try #require(results[index]) {
        case let .success(token):
          #expect(!token.isEmpty)
          let status = try await ComputerFileSystem.local.status(write.target.path)
          #expect(token == status.version)
          #expect(status.size == UInt64(write.bytes.count))
          let landed = try Data(contentsOf: write.target)
          #expect(landed == write.bytes)
          #expect(sha256(landed) == sha256(write.bytes))
        case let .failure(error):
          Issue.record(error, "Honest 8 MiB write failed on \(write.machine.rawValue)")
          failed = true
        }
      }
      if failed { try await stopOutstandingFileWrites(in: transfer.space) }
      try await waitForNoFileOperations(in: transfer.space)
      let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
      #expect(!names.contains { $0.hasPrefix(".wuhu-write-") })
      if !failed { #expect(Set(names) == Set(writes.map { $0.target.lastPathComponent })) }
    }
  }

  @Test(arguments: [false, true])
  func callerFailureAfterARealPrefixStopsAndUnlinksBeforeFixtureShutdown(cancel: Bool) async throws {
    let folder = try ScratchFolder("real-write-stop")
    let target = folder.url.appending(path: "target")
    let prefix = Data(repeating: 7, count: 65536)
    let appended = AsyncStream<Void>.makeStream()
    let prefixAccepted = AsyncStream<Void>.makeStream()
    let closed = AsyncStream<Void>.makeStream()
    let proceed = AsyncStream<Void>.makeStream()
    let stops = Mutex<[String]>([])
    let files = observingLocalWriter(appended: appended.continuation, closed: closed.continuation)
    try await withMachines(["b": fileOperationKinds(files: files)], intercept: { _, request in
      if request.method == .put, request.url.path.hasSuffix("/stop") {
        let body = try #require(request.body?.replay())
        let stop = try await body.json(StopRequest.self)
        stops.withLock { $0.append(stop.reason) }
      }
    }) { transfer in
      try await withThrowingTaskGroup(of: Result<Void, any Error>.self) { group in
        group.addTask {
          defer { prefixAccepted.continuation.finish() }
          do {
            let connection = try MachineFileClient(space: transfer.space, machine: b, caller: nil).connect(.init(kind: "write.v1", input: ["path": .string(target.path), "bytes": "131072", "digest": .string(sha256(prefix + prefix))]))
            defer { connection.close() }
            try await connection.write("data", .init(data: prefix))
            prefixAccepted.continuation.yield()
            for await _ in proceed.stream {}
            try Task.checkCancellation()
            try await connection.write("unadvertised", .init(data: prefix))
            return .success(())
          } catch { return .failure(error) }
        }
        defer { proceed.continuation.finish(); group.cancelAll() }
        var accepted = prefixAccepted.stream.makeAsyncIterator()
        _ = try #require(await accepted.next())
        for await _ in appended.stream { break }
        let stages = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(stages.count == 1)
        let stage = try #require(stages.first)
        #expect(stage.hasPrefix(".wuhu-write-"))
        #expect(try Data(contentsOf: folder.url.appending(path: stage)) == prefix)
        if cancel { group.cancelAll() }
        else { proceed.continuation.finish() }
        switch try #require(try await group.next()) {
        case .success: Issue.record("Expected caller failure before EOF")
        case let .failure(error):
          if cancel { #expect(error is CancellationError) }
          else { #expect((error as? OperationError)?.code == .invalidInput) }
        }
        for await _ in closed.stream { break }
        try await waitForNoFileOperations(in: transfer.space)
        let stopReasons = stops.withLock { $0 }
        #expect(stopReasons == ["callerGone"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
      }
    }
  }

  @Test func cancellingAfterAppendBeforeTheInputReplyAllowsTheSamePathToBeWrittenAgain() async throws {
    let folder = try ScratchFolder("real-write-in-flight-stop")
    let target = folder.url.appending(path: "target")
    let prefix = Data(repeating: 11, count: 4 << 20)
    let appended = AsyncStream<Void>.makeStream()
    let closed = AsyncStream<Void>.makeStream()
    let callerClosed = AsyncStream<Void>.makeStream()
    let replyHeld = AsyncStream<Void>.makeStream()
    let releaseReply = AsyncStream<Void>.makeStream()
    let files = observingLocalWriter(appended: appended.continuation, closed: closed.continuation)
    defer { releaseReply.continuation.finish() }
    let inputs = Mutex(0)
    try await withMachines(["b": fileOperationKinds(files: files)], interceptResponse: { _, request, response in
      if request.method == .put, request.url.path.hasSuffix("/inputs/data"), inputs.withLock({ $0 += 1; return $0 }) == 1 {
        replyHeld.continuation.yield()
        for await _ in releaseReply.stream {}
      }
      return response
    }) { transfer in
      let client = MachineFileClient(space: transfer.space, machine: b, caller: nil)
      try await withThrowingTaskGroup(of: Result<Void, any Error>.self) { group in
        group.addTask {
          do {
            let connection = try client.connect(.init(kind: "write.v1", input: ["path": .string(target.path), "bytes": .string(String(2 * prefix.count)), "digest": .string(sha256(prefix + prefix))]))
            defer {
              connection.close()
              callerClosed.continuation.yield()
              callerClosed.continuation.finish()
            }
            try await connection.write("data", .init(data: prefix + prefix), end: true)
            _ = try await connection.result()
            return .success(())
          } catch { return .failure(error) }
        }
        defer { releaseReply.continuation.finish(); group.cancelAll() }
        for await _ in replyHeld.stream { break }
        for await _ in appended.stream { break }
        let accepted = try await client.space.worker.call(MachineCell.ID(client.machine.rawValue)) { cell in
          let socket = cell.ctx.sockets(of: FileBulk.self).first!
          return cell.fileOperation(socket.opening.request.operation)!.inputOffsets["data"]!
        }
        #expect(accepted == 0)
        let stages = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(stages.count == 1)
        let stage = try #require(stages.first)
        #expect(stage.hasPrefix(".wuhu-write-"))
        #expect(try Data(contentsOf: folder.url.appending(path: stage)) == prefix)
        group.cancelAll()
        switch try #require(try await group.next()) {
        case .success: Issue.record("Expected in-flight write cancellation")
        case let .failure(error): #expect(error is CancellationError)
        }
        for await _ in callerClosed.stream { break }
        releaseReply.continuation.finish()
        for await _ in closed.stream { break }
        try await waitForNoFileOperations(in: client.space)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
      }
      let replacement = Data((0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8)) })
      let token = try await client.write(target.path, data: replacement, ifMatch: nil)
      let status = try await files.status(target.path)
      #expect(!token.isEmpty)
      #expect(token == status.version)
      #expect(status.size == UInt64(replacement.count))
      let landed = try Data(contentsOf: target)
      #expect(landed == replacement)
      #expect(sha256(landed) == sha256(replacement))
      try await waitForNoFileOperations(in: client.space)
      #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["target"])
    }
  }
}

private struct RealFileWrite: Sendable {
  let machine: MachineID
  let target: URL
  let bytes: Data
}

private func waitForNoFileOperations(in space: Space) async throws {
  let writer = await space.writer
  let counts = ValueObservation.tracking { db in
    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM machine_file_operations")!
  }.values(in: writer, bufferingPolicy: .bufferingNewest(1))
  for try await count in counts {
    if count == 0 { return }
  }
  Issue.record("File-operation observation ended before retirement")
}

private func stopOutstandingFileWrites(in space: Space) async throws {
  let writer = await space.writer
  let operations = try await writer.read { db in
    try Row.fetchAll(db, sql: "SELECT id, owner FROM machine_file_operations").map { row -> (UUID, String) in
      (UUID(uuidString: row["id"])!, row["owner"])
    }
  }
  for (operation, machine) in operations {
    try await space.worker.call(MachineCell.ID(machine)) { cell in
      if var row = cell.fileOperation(operation) {
        try cell.failFile(&row, .operation(.init(.requestCancelled, message: "failed test write cleanup")))
      }
    }
  }
}

private func observingLocalWriter(appended: AsyncStream<Void>.Continuation, closed: AsyncStream<Void>.Continuation) -> ComputerFileSystem {
  let files = ComputerFileSystem.local
  let operations = files.operations
  return ComputerFileSystem(status: files.status, read: files.read, search: files.search, abandonedEffects: files.abandonedEffects, operations: .init(stat: operations.stat, list: operations.list, write: { path, condition in
    let writer = try await operations.write(path, condition)
    return ComputerWriter(append: { bytes in
      try await writer.append(bytes)
      appended.yield()
    }, prepare: writer.prepare, commit: writer.commit, close: {
      await writer.close()
      closed.yield()
      closed.finish()
    })
  }, mkdir: operations.mkdir, remove: operations.remove, move: operations.move))
}
