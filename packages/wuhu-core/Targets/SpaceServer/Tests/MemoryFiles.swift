#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import SpaceServer

actor MemoryFiles {
  private var files: [String: Data] = [:]

  func read(_ name: String) throws -> Data {
    guard let data = files[name] else { throw IdentityError.keyUnavailable }
    return data
  }

  func load(_ name: String) -> Data? { files[name] }
  func write(_ data: Data, at name: String) { files[name] = data }
  func create(_ name: String, data: Data) throws {
    guard files[name] == nil else { throw IdentityError.keyUnavailable }
    files[name] = data
  }

  func remove(_ name: String) { files[name] = nil }

  nonisolated func keyStore(_ name: String) -> KeyFileStore {
    .init(load: { await self.load(name) }, create: { try await self.create(name, data: $0) })
  }

  nonisolated var identityStateStore: IdentityStateStore {
    .init(load: { await self.load("/settings.json") }, save: { await self.write($0, at: "/settings.json") })
  }
}
