import Foundation
import SpaceFS
import Testing

private struct TaggedVFS: SpaceVFS {
  let id: Int
  func read(_: String) async throws -> (VersionToken, Data) { throw CancellationError() }
  func write(_: String, _: Data, ifMatch _: VersionToken?) async throws -> VersionToken { throw CancellationError() }
  func delete(_: String, ifMatch _: VersionToken?) async throws { throw CancellationError() }
  func move(_: String, to _: String) async throws { throw CancellationError() }
  func list(_: String) async throws -> (VersionToken, [Entry]) { throw CancellationError() }
  func stat(_: String) async throws -> Entry { throw CancellationError() }
}

private let resolver = FSResolver(
  space: TaggedVFS(id: 0),
  spaceAt: { TaggedVFS(id: 1000 + $0) },
  machine: { TaggedVFS(id: 2000 + Int($0.dropFirst(2))!) },
  system: TaggedVFS(id: 3000),
  group: { name, rev in TaggedVFS(id: 4000 + name.count * 10 + (rev ?? 0)) },
)

private func backendID(_ backend: any SpaceVFS) -> Int? {
  (backend as? TaggedVFS)?.id
}

struct FSResolverTests {
  @Test func `a bare absolute path targets the space backend`() throws {
    let resolved = try resolver.resolve("/notes/todo.md")
    #expect(backendID(resolved.backend) == 0)
    #expect(resolved.path == "/notes/todo.md")
    #expect(resolved.machine == nil)
  }

  @Test func `a trailing revision routes through the revision factory`() throws {
    let bareRev = try resolver.resolve("/notes/todo.md@3")
    #expect(backendID(bareRev.backend) == 1003)
    #expect(bareRev.path == "/notes/todo.md")

    let zero = try resolver.resolve("/x@0")
    #expect(backendID(zero.backend) == 1000)
    #expect(zero.path == "/x")
  }

  @Test func `a residual at that is not a revision is an invalid address, never a pass-through`() {
    #expect(throws: FSResolveError.invalidAddress("/notes/todo@abc")) {
      try resolver.resolve("/notes/todo@abc")
    }
    #expect(throws: FSResolveError.invalidAddress("/x@-1")) { try resolver.resolve("/x@-1") }
    // Revision splits off the trailing @3, leaving "/a@b", which is itself invalid.
    #expect(throws: FSResolveError.invalidAddress("/a@b")) { try resolver.resolve("/a@b@3") }
  }

  @Test func `an all-digit revision that overflows Int is an invalid address, not a head misroute`() {
    #expect(throws: FSResolveError.invalidAddress("/x@99999999999999999999")) {
      try resolver.resolve("/x@99999999999999999999")
    }
  }

  @Test func `the resolved path is the canonical NFC space path`() throws {
    let path = try resolver.resolve("/notes/cafe\u{0301}.md").path
    #expect(path == "/notes/caf\u{00E9}.md")
    #expect(Array(path.utf8) == Array("/notes/caf\u{00E9}.md".utf8))
  }

  @Test func `a grammar-invalid space path is an invalid address`() {
    #expect(throws: FSResolveError.invalidAddress("/notes//todo.md")) {
      try resolver.resolve("/notes//todo.md")
    }
  }

  @Test func `a wuhu authority with an empty host is an invalid address`() {
    #expect(throws: FSResolveError.invalidAddress("wuhu:///foo")) { try resolver.resolve("wuhu:///foo") }
    #expect(throws: FSResolveError.invalidAddress("wuhu://")) { try resolver.resolve("wuhu://") }
  }

  @Test func `every wuhu host but system is refused with the accepted forms named`() {
    for address in [
      "wuhu://local/x.md", "WUHU://Local/x.md", "wuhu://local", "wuhu://peer:5530/notes/todo.md",
      "wuhu://system:5530/AGENTS.md", "wuhu://system.example/AGENTS.md",
    ] {
      #expect(throws: FSResolveError.unsupportedHost(address)) { try resolver.resolve(address) }
    }
    #expect("\(FSResolveError.unsupportedHost("wuhu://local/x.md"))" == "not a file address: wuhu://local/x.md; use /<path> for this group, wuhu://<group>.localspace/<path> for another group, machines://<machine>/<path> for a machine or wuhu://system/<path> for the system files")
  }

  @Test func `a localspace host routes to that group, revisions included`() throws {
    let resolved = try resolver.resolve("wuhu://alice.localspace/notes/plan.md")
    #expect(backendID(resolved.backend) == 4050)
    #expect(resolved.path == "/notes/plan.md")
    #expect(resolved.group == "alice")
    #expect(resolved.machine == nil && !resolved.system)

    #expect(backendID(try resolver.resolve("WUHU://Alice.LocalSpace/x@3").backend) == 4053)
    #expect(try resolver.resolve("wuhu://alice.localspace").path == "/")
    #expect(try resolver.resolve("/x").group == nil)
  }

  @Test func `a localspace host that names no group is an invalid address`() {
    for address in ["wuhu://localspace/x", "wuhu://.localspace/x", "wuhu://Bad_Id.localspace/x", "wuhu://-a.localspace/x"] {
      #expect(throws: FSResolveError.invalidAddress(address)) { try resolver.resolve(address) }
    }
  }

  @Test func `the system host routes to the system backend with a space-grammar path`() throws {
    let resolved = try resolver.resolve("wuhu://system/skills/monitor/SKILL.md")
    #expect(backendID(resolved.backend) == 3000)
    #expect(resolved.path == "/skills/monitor/SKILL.md")
    #expect(resolved.system)
    #expect(resolved.machine == nil)

    #expect(try resolver.resolve("wuhu://system").path == "/")
    #expect(try resolver.resolve("WUHU://System/AGENTS.md").system)
    #expect(!(try resolver.resolve("/AGENTS.md").system))
    #expect(throws: FSResolveError.invalidAddress("wuhu://system/AGENTS.md@3")) {
      try resolver.resolve("wuhu://system/AGENTS.md@3")
    }
  }

  @Test func `a machines address routes to the machine backend with the raw local path`() throws {
    let resolved = try resolver.resolve("machines://m_7/etc/hosts")
    #expect(backendID(resolved.backend) == 2007)
    #expect(resolved.path == "/etc/hosts")
    #expect(resolved.machine == "m_7")

    let bare = try resolver.resolve("machines://m_7")
    #expect(bare.path == "/")

    // Machine paths are raw: the space grammar does not apply.
    let raw = try resolver.resolve("machines://m_7/tmp//weird name/a@b.txt")
    #expect(raw.path == "/tmp//weird name/a@b.txt")
  }

  @Test func `a revision suffix on a machines address is rejected, never stripped`() {
    #expect(throws: FSResolveError.machineRevision("machines://m_7/etc/hosts@3")) {
      try resolver.resolve("machines://m_7/etc/hosts@3")
    }
    #expect(throws: FSResolveError.invalidAddress("machines://")) { try resolver.resolve("machines://") }
  }

  @Test func `an address with neither scheme nor leading slash is invalid`() {
    #expect(throws: FSResolveError.invalidAddress("notes/todo.md")) {
      try resolver.resolve("notes/todo.md")
    }
  }
}
