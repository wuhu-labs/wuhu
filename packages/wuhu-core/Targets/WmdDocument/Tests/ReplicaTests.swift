#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Loro
import Testing
@testable import WmdDocument

extension WmdReplica {
  /// Merges like the node does: the update first, then its import.
  @discardableResult
  func write(_ markdown: String, base: Data? = nil, peer: UInt64) throws -> Data? {
    guard let update = try merge(markdown: markdown, base: base, peer: peer) else { return nil }
    try importUpdate(update)
    return update
  }

  /// A person's keystrokes straight into the Loro blocks, as an update.
  func type(_ edit: (LoroMovableList) throws -> Void) throws -> Data {
    let before = doc.oplogVv()
    try edit(doc.getMovableList(id: "blocks"))
    doc.commit()
    return try doc.export(mode: .updates(from: before))
  }
}

private func text(_ list: LoroMovableList, _ position: UInt32) throws -> LoroText {
  try list.get(index: position)!.asLoroMap()!.getOrCreateTextContainer(key: "text", child: LoroText())
}

@Suite struct ReplicaTests {
  static let start = "# Plan\n\nFirst paragraph here.\n\nSecond paragraph here.\n\n- one\n- two\n"

  /// A client replica caught up with `live`, the way the live channel's handshake leaves it.
  static func client(of live: WmdReplica) throws -> WmdReplica {
    let client = WmdReplica()
    try client.importUpdate(#require(try live.updates(since: client.versionVector)))
    return client
  }

  @Test func writeIntoAnEmptyDocReadsBackCanonical() throws {
    let live = WmdReplica()
    let update = try live.write("#  Plan\n- one\n", peer: 101)
    #expect(update != nil)
    #expect(live.markdown == "# Plan\n\n- one\n")
    #expect(try live.merge(markdown: live.markdown, base: nil, peer: 102) == nil)
  }

  @Test func agentEditMergesWithConcurrentTypingFromItsReadVersion() throws {
    let live = WmdReplica()
    try live.write(Self.start, peer: 103)
    let agentRead = live.frontiers
    let agentText = try live.markdown(at: agentRead)
    #expect(agentText == Self.start)

    let human = try Self.client(of: live)
    let typed = try #require(try human.write(Self.start.replacing("First paragraph here.", with: "First paragraph here, typed by a person."), peer: 104))
    try live.importUpdate(typed)

    let agentUpdate = try #require(try live.write(agentText.replacing("Second", with: "Edited second").replacing("- two\n", with: "- two\n- [ ] three\n"), base: agentRead, peer: 105))
    #expect(live.markdown == "# Plan\n\nFirst paragraph here, typed by a person.\n\nEdited second paragraph here.\n\n- one\n- two\n- [ ] three\n")

    try human.importUpdate(agentUpdate)
    #expect(human.markdown == live.markdown)
  }

  @Test func editsInsideOneParagraphInterleave() throws {
    let live = WmdReplica()
    try live.write("alpha beta gamma\n", peer: 106)
    let agentRead = live.frontiers
    let human = try Self.client(of: live)
    try live.importUpdate(#require(try human.write("alpha beta gamma delta\n", peer: 107)))
    try live.write("**alpha** beta gamma\n", base: agentRead, peer: 108)
    #expect(live.markdown == "**alpha** beta gamma delta\n")
  }

  @Test func rebuildFromSnapshotAndLog() throws {
    let live = WmdReplica()
    let first = try #require(try live.write("a\n", peer: 109))
    let snapshot = try live.snapshot()
    let second = try #require(try live.write("a\n\nb\n", peer: 110))
    let rebuilt = try WmdReplica(snapshot: snapshot, updates: [second])
    #expect(rebuilt.markdown == "a\n\nb\n")
    let replayed = try WmdReplica(snapshot: nil, updates: [first, second])
    #expect(replayed.markdown == "a\n\nb\n")
    #expect(try rebuilt.updates(since: live.versionVector) == nil)
  }

  @Test func updateWithoutItsDependenciesIsRefused() throws {
    let source = WmdReplica()
    try source.write("a\n", peer: 111)
    let base = source.versionVector
    try source.write("a\n\nb\n", peer: 112)
    let tail = try #require(try source.updates(since: base))
    #expect(throws: WmdError.missingDependencies) { try WmdReplica().importUpdate(tail) }
  }

  @Test func syntaxErrorsSurfaceFromMerge() {
    #expect(throws: WmdError.syntax(WmdSyntaxError(line: 1, problem: .quote))) {
      try WmdReplica().merge(markdown: "> no\n", base: nil, peer: 113)
    }
  }

  @Test func mergeLeavesTheReplicaAsItWas() throws {
    let live = WmdReplica()
    try live.write("a\n", peer: 114)
    let update = try #require(try live.merge(markdown: "a\n\nb\n", base: nil, peer: 115))
    #expect(live.markdown == "a\n")
    try live.importUpdate(update)
    #expect(live.markdown == "a\n\nb\n")
  }

  @Test func severalBlocksChangedInARowEachStayInTheirContainer() throws {
    let live = WmdReplica()
    try live.write("alpha one\n\nbravo two\n\ncharlie three\n\ndelta four\n\necho five\n", peer: 116)
    let agentRead = live.frontiers
    let human = try Self.client(of: live)
    try live.importUpdate(human.type { try text($0, 2).insert(pos: 0, s: "typed ") })
    try live.write("alpha one\n\nbravo 2\n\ncharlie 3\n\ndelta 4\n\necho five\n", base: agentRead, peer: 117)
    #expect(live.markdown == "alpha one\n\nbravo 2\n\ntyped charlie 3\n\ndelta 4\n\necho five\n")
  }

  /// A person pressed Enter after B and types into the empty paragraph while the agent edits C.
  @Test func anEmptyParagraphTheAgentNeverSawIsLeftAlone() throws {
    let live = WmdReplica()
    try live.write("Apple\n\nBanana split\n\nCherry pie recipe\n", peer: 118)
    let human = try Self.client(of: live)
    try live.importUpdate(human.type { list in
      let empty = try list.insertMapContainer(pos: 2, child: LoroMap())
      try empty.insert(key: "kind", v: "paragraph")
      _ = try empty.getOrCreateTextContainer(key: "text", child: LoroText())
    })
    let agentRead = live.frontiers
    #expect(live.markdown == "Apple\n\nBanana split\n\nCherry pie recipe\n")
    try live.importUpdate(human.type { try text($0, 2).insert(pos: 0, s: "hello") })
    let agentUpdate = try #require(try live.write("Apple\n\nBanana split\n\nCherry pie recipes\n", base: agentRead, peer: 119))
    #expect(live.markdown == "Apple\n\nBanana split\n\nhello\n\nCherry pie recipes\n")
    try human.importUpdate(agentUpdate)
    #expect(human.markdown == live.markdown)
  }

  @Test func deletingOneBlockAndEditingTheNextKeepsTypingInTheEditedOne() throws {
    let live = WmdReplica()
    try live.write("Apple\n\nBanana split\n\nCherry pie recipe\n\nDate\n", peer: 120)
    let agentRead = live.frontiers
    let human = try Self.client(of: live)
    try live.importUpdate(human.type { try text($0, 2).insert(pos: 0, s: "My ") })
    try live.write("Apple\n\nCherry pie recipes\n\nDate\n", base: agentRead, peer: 121)
    #expect(live.markdown == "Apple\n\nMy Cherry pie recipes\n\nDate\n")
  }

  @Test func aListItemWithABlankLineStaysWritable() throws {
    let live = WmdReplica()
    try live.write("- one\n    - two\n", peer: 122)
    try live.importUpdate(live.type { list in
      try text(list, 0).insert(pos: 3, s: "\n\nmore")
      try text(list, 1).insert(pos: 3, s: "\n\n\nnested")
    })
    let markdown = live.markdown
    #expect(markdown == "- one\n\n    more\n    - two\n\n\n        nested\n")
    #expect(try live.merge(markdown: markdown, base: nil, peer: 123) == nil)
    try live.write(markdown.replacing("more", with: "most"), peer: 124)
    #expect(live.markdown == "- one\n\n    most\n    - two\n\n\n        nested\n")
  }
}
