import Foundation
import Testing
import WuhuVFS

struct VFSResolverTests {
  @Test func `empty resolver reports missing filesystem`() async throws {
    await #expect(throws: VFSResolverError.notFound(scheme: "wuhu", host: "default.local")) {
      _ = try await VFSResolver.empty.resolve("wuhu", "default.local")
    }
  }

  @Test func `constant resolver resolves by exact scheme and host`() async throws {
    let root = InMemoryVFSNode()
    try await root.seedFile(at: try path(["note.txt"]), data: Data("hello".utf8))
    let resolver = VFSResolver.constant([
      ("wuhu", "default.local", NodeTreeVFS(root: root)),
    ])

    let filesystem = try await resolver.resolve("wuhu", "default.local")

    #expect(try await filesystem.readText(at: try path(["note.txt"])) == "hello")
    await #expect(throws: VFSResolverError.notFound(scheme: "Wuhu", host: "default.local")) {
      _ = try await resolver.resolve("Wuhu", "default.local")
    }
  }

  @Test func `middleware can transform resolved filesystems`() async throws {
    let root = InMemoryVFSNode()
    try await root.seedFile(at: try path(["note.txt"]), data: Data("hello".utf8))
    let resolver = VFSResolver.constant([
      ("blob", "session", NodeTreeVFS(root: root)),
    ]).middleware { scheme, host, next in
      let filesystem = try await next(scheme, host)
      guard scheme == "blob" else { return filesystem }
      return filesystem.readOnly()
    }

    let filesystem = try await resolver.resolve("blob", "session")

    #expect(try await filesystem.readText(at: try path(["note.txt"])) == "hello")
    await #expect(throws: VFSNodeError.immutable) {
      try await filesystem.writeText("blocked", at: try path(["note.txt"]), append: false)
    }
  }
}
