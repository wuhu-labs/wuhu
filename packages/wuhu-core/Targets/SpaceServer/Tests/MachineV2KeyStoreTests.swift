import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif
import Crypto
import OperationClient
import OperationProtocol
import Scratch
import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.deterministicDependencies) struct MachineV2KeyStoreTests {
  @Test func durableDiskKeyAndNewTableCheckSurviveDatabaseReopen() async throws {
    let folder = try ScratchFolder("v2-durable-key")
    let database = folder.url.appendingPathComponent("space.sqlite")
    let directory = folder.url.appendingPathComponent("private-state")
    let space = try Space.open(file: database)
    let key = try await MachineV2KeyStore.loadOrCreate(directory: directory, space: space)
    let bytes = key.withUnsafeBytes { Data($0) }
    #expect(bytes.count == 32)
    let store = try await space.machineV2Store(group: .shared, key: key)
    let record = Self.record(machine: try await space.addMachineV2(name: "disk").machine.id.rawValue)
    _ = try await store.claim(.init(scope: "dead-script", key: "one"), record: record)
    let reopened = try Space.open(file: database)
    let next = try await MachineV2KeyStore.loadOrCreate(directory: directory, space: reopened)
    #expect(next.withUnsafeBytes { Data($0) } == bytes)
    let restored = try await reopened.machineV2Store(group: .shared, key: next)
    #expect(try await restored.read(record.id).start.input == record.start.input)
    var info = stat()
    #expect(lstat(directory.appendingPathComponent(MachineV2KeyStore.filename).path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(lstat(directory.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o700)
  }

  @Test func missingKeyNeverRecreatesEvenWithoutOperationRows() async throws {
    let fs = MemoryFiles()
    let space = try Space.inMemory()
    _ = try await MachineV2KeyStore.loadOrCreate(from: fs.keyStore("/machine-v2.key"), space: space)
    let path = "/" + MachineV2KeyStore.filename
    await fs.remove(path)
    await #expect(throws: OperationError.self) { try await MachineV2KeyStore.loadOrCreate(from: fs.keyStore("/machine-v2.key"), space: space) }
    #expect(await fs.load(path) == nil)
  }

  @Test func preexistingEncryptedOperationsRequireOriginalKeyWithoutBackfill() async throws {
    let fs = MemoryFiles()
    let space = try Space.inMemory()
    let key = SymmetricKey(size: .bits256)
    let store = try await space.machineV2Store(group: .shared, key: key)
    let record = Self.record(machine: try await space.addMachineV2(name: "disk").machine.id.rawValue)
    _ = try await store.claim(.init(scope: "prior-slice", key: "one"), record: record)
    await #expect(throws: OperationError.self) { try await MachineV2KeyStore.loadOrCreate(from: fs.keyStore("/machine-v2.key"), space: space) }
    let path = "/" + MachineV2KeyStore.filename
    #expect(await fs.load(path) == nil)
    try await fs.create(path, data: Data(repeating: 17, count: 32))
    await #expect(throws: OperationError.self) { try await MachineV2KeyStore.loadOrCreate(from: fs.keyStore("/machine-v2.key"), space: space) }
    #expect(try await fs.read(path) == Data(repeating: 17, count: 32))
    await fs.write(key.withUnsafeBytes { Data($0) }, at: path)
    _ = try await MachineV2KeyStore.loadOrCreate(from: fs.keyStore("/machine-v2.key"), space: space)
    #expect(try await store.read(record.id).start.input == record.start.input)
  }

  @Test func corruptOrWrongKeyIsTypedAndNeverOverwritten() async throws {
    let fs = MemoryFiles()
    let space = try Space.inMemory()
    _ = try await MachineV2KeyStore.loadOrCreate(from: fs.keyStore("/machine-v2.key"), space: space)
    let path = "/" + MachineV2KeyStore.filename
    for bad in [Data([1, 2]), Data(repeating: 0, count: 32)] {
      await fs.write(bad, at: path)
      do { _ = try await MachineV2KeyStore.loadOrCreate(from: fs.keyStore("/machine-v2.key"), space: space); Issue.record("wrong key accepted") }
      catch let error as OperationError { #expect(error.code == .storeUnavailable) }
      #expect(try await fs.read(path) == bad)
    }
  }

  @Test func symlinkKeyIsRefused() async throws {
    let folder = try ScratchFolder("v2-key-link")
    let directory = folder.url.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = folder.url.appendingPathComponent("other.key")
    let bytes = Data(repeating: 17, count: 32)
    try bytes.write(to: target)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(MachineV2KeyStore.filename), withDestinationURL: target)
    await #expect(throws: OperationError.self) { try await MachineV2KeyStore.loadOrCreate(directory: directory, space: Space.inMemory()) }
    #expect(try Data(contentsOf: target) == bytes)
  }

  private static func record(machine: String) -> ClientRecord {
    .init(id: UUID(), correlation: UUID(), machine: machine, start: .init(kind: "read.v1", input: ["path": "/private"]), description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read]))
  }
}

extension MachineV2KeyStoreTests {
  @Test func concurrentProvisioningCannotOverwriteAnotherStartupKey() async throws {
    let folder = try ScratchFolder("v2-key-provision-race")
    let directory = folder.url.appendingPathComponent("state")
    let space = try Space.inMemory()
    let keys = try await withThrowingTaskGroup(of: Data?.self) { tasks in
      for _ in 0 ..< 12 {
        tasks.addTask {
          do {
            let key = try await MachineV2KeyStore.loadOrCreate(directory: directory, space: space)
            return key.withUnsafeBytes { Data($0) }
          } catch let error as OperationError {
            #expect(error.code == .storeUnavailable)
            return nil
          }
        }
      }
      var values: [Data] = []
      for try await value in tasks { if let value { values.append(value) } }
      return values
    }
    let first = try #require(keys.first)
    #expect(keys.allSatisfy { $0 == first })
    let reopened = try await MachineV2KeyStore.loadOrCreate(directory: directory, space: space)
    #expect(reopened.withUnsafeBytes { Data($0) } == first)
  }
}
