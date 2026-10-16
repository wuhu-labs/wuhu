import Foundation
import GRDB
import JSONValue
@testable import SessionTools
import SpaceContract
@testable import SpaceCore
import Testing

// `find` and `grep` in `wuhu:space` run the find and grep tools as the
// session: the same matches, limits and step cursors, over the groups its
// group reads, with failures as SpaceErrors.
@Suite struct ScriptSearchTests {
  @Test func findAndGrepPageThroughOwnAndReadableGroupsWithTypedErrors() async throws {
    let alice = GroupID(rawValue: "alice")
    try await withRig(group: alice, prepare: { space, _ in
      try await space.writer.write { db in
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('bob', '2026-01-01T00:00:00.000Z')")
      }
      let files: [(GroupID, String, String)] = [
        (alice, "/notes/a.md", "alpha\nTODO one\n"),
        (alice, "/notes/b.md", "TODO two\nTODO three\n"),
        (alice, "/notes/c.txt", "TODO not markdown\n"),
        (.shared, "/docs/s.md", "TODO shared\n"),
        (GroupID(rawValue: "bob"), "/secret.md", "TODO bob\n"),
      ]
      for (group, path, text) in files {
        _ = try await space.fs(group).write(path, Data(text.utf8), ifMatch: nil)
      }
    }) { rig in
      let value = try await rig.evaluate(#"""
      import { find, grep } from "wuhu:space"
      const codes = []
      const attempt = async (f) => {
        try { await f(); codes.push("ok") } catch (e) { codes.push(e.name === "SpaceError" ? e.code : e.name) }
      }
      const own = await find("**/*.md", { path: "/notes" })
      const first = await find("**/*.md", { path: "/notes", limit: 1 })
      const second = await find("**/*.md", { path: "/notes", limit: 1, step: first.step })
      const scanned = await find("**/*.md", { path: "/notes", entryLimit: 1 })
      const shared = await find("**/*.md", { path: "wuhu://shared.localspace/docs" })
      const page1 = await grep("^TODO", { path: "/notes", limit: 2 })
      const page2 = await grep("^TODO", { path: "/notes", limit: 2, step: page1.step })
      const sharedGrep = await grep("TODO", { path: "wuhu://shared.localspace/docs" })
      await attempt(() => grep("(", { path: "/notes" }))
      await attempt(() => grep("x", { path: "/notes", step: "nope" }))
      await attempt(() => find("*", { path: "/notes", limit: 0 }))
      await attempt(() => find("*", { path: "relative/notes" }))
      await attempt(() => find("*", { path: "/missing" }))
      await attempt(() => grep("TODO", { path: "wuhu://bob.localspace/" }))
      await attempt(() => find("*", { path: "machines://mc_abcdefgh/tmp" }))
      await attempt(() => find("*", { limit: "2" }))
      await attempt(() => find("*", { max: 1 }))
      await attempt(() => find(""))
      await attempt(() => grep("TODO", { path: "/notes", step: first.step }))
      await attempt(() => find("**/*.md", { path: "/", step: first.step }))
      // steps are opaque: only whether there is one is compared
      const shape = (r) => ({ ...r, step: r.step === null ? null : typeof r.step })
      result({
        own: shape(own), first: shape(first), second: shape(second), scanned: shape(scanned), shared: shape(shared),
        page1: shape(page1), page2: shape(page2), sharedGrep: shape(sharedGrep), codes,
      })
      """#)
      let object = try #require(value.object)
      #expect(object["own"] == ["paths": ["/notes/a.md", "/notes/b.md"], "step": .null])
      #expect(object["first"] == ["paths": ["/notes/a.md"], "step": "string"])
      #expect(object["second"] == ["paths": ["/notes/b.md"], "step": .null])
      #expect(object["scanned"] == ["paths": ["/notes/a.md"], "step": "string"], "an exhausted entry budget hands back a step")
      #expect(object["shared"] == ["paths": ["wuhu://shared.localspace/docs/s.md"], "step": .null])
      #expect(object["page1"] == [
        "matches": [
          ["path": "/notes/a.md", "line": 2, "text": "TODO one"],
          ["path": "/notes/b.md", "line": 1, "text": "TODO two"],
        ],
        "step": "string",
        "skipped": [],
      ])
      #expect(object["page2"] == [
        "matches": [["path": "/notes/b.md", "line": 2, "text": "TODO three"], ["path": "/notes/c.txt", "line": 1, "text": "TODO not markdown"]],
        "step": .null,
        "skipped": [],
      ])
      #expect(object["sharedGrep"] == [
        "matches": [["path": "wuhu://shared.localspace/docs/s.md", "line": 1, "text": "TODO shared"]], "step": .null, "skipped": [],
      ])
      #expect(object["codes"] == [
        "invalidArgument", "invalidArgument", "invalidArgument", "invalidPath", "notFound", "notFound", "unavailable",
        "TypeError", "TypeError", "TypeError", "invalidArgument", "invalidArgument",
      ])
    }
  }
}
