#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LiveDocument
import Loro
import Testing
import WmdDocument

extension LiveReplica {
  /// Merges like the node does: the update first, then its import.
  @discardableResult
  func write(_ markdown: String, base: Data? = nil, peer: UInt64) throws -> Data? {
    guard let update = try merge(text: markdown, base: base, peer: peer)?.update else { return nil }
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
  static func client(of live: LiveReplica) throws -> LiveReplica {
    let client = LiveReplica(.wmd)
    try client.importUpdate(#require(try live.updates(since: client.versionVector)))
    return client
  }

  @Test func writeIntoAnEmptyDocReadsBackCanonical() throws {
    let live = LiveReplica(.wmd)
    let update = try live.write("#  Plan\n- one\n", peer: 101)
    #expect(update != nil)
    #expect(live.text == "# Plan\n\n- one\n")
    #expect(try live.merge(text: live.text, base: nil, peer: 102) == nil)
  }

  @Test func agentEditMergesWithConcurrentTypingFromItsReadVersion() throws {
    let live = LiveReplica(.wmd)
    try live.write(Self.start, peer: 103)
    let agentRead = live.frontiers
    let agentText = try live.text(at: agentRead)
    #expect(agentText == Self.start)

    let human = try Self.client(of: live)
    let typed = try #require(try human.write(Self.start.replacing("First paragraph here.", with: "First paragraph here, typed by a person."), peer: 104))
    try live.importUpdate(typed)

    let agentUpdate = try #require(try live.write(agentText.replacing("Second", with: "Edited second").replacing("- two\n", with: "- two\n- [ ] three\n"), base: agentRead, peer: 105))
    #expect(live.text == "# Plan\n\nFirst paragraph here, typed by a person.\n\nEdited second paragraph here.\n\n- one\n- two\n- [ ] three\n")

    try human.importUpdate(agentUpdate)
    #expect(human.text == live.text)
  }

  @Test func editsInsideOneParagraphInterleave() throws {
    let live = LiveReplica(.wmd)
    try live.write("alpha beta gamma\n", peer: 106)
    let agentRead = live.frontiers
    let human = try Self.client(of: live)
    try live.importUpdate(#require(try human.write("alpha beta gamma delta\n", peer: 107)))
    try live.write("**alpha** beta gamma\n", base: agentRead, peer: 108)
    #expect(live.text == "**alpha** beta gamma delta\n")
  }

  @Test func rebuildFromSnapshotAndLog() throws {
    let live = LiveReplica(.wmd)
    let first = try #require(try live.write("a\n", peer: 109))
    let snapshot = try live.snapshot()
    let second = try #require(try live.write("a\n\nb\n", peer: 110))
    let rebuilt = try LiveReplica(.wmd, snapshot: snapshot, updates: [second])
    #expect(rebuilt.text == "a\n\nb\n")
    let replayed = try LiveReplica(.wmd, snapshot: nil, updates: [first, second])
    #expect(replayed.text == "a\n\nb\n")
    #expect(try rebuilt.updates(since: live.versionVector) == nil)
  }

  @Test func updateWithoutItsDependenciesIsRefused() throws {
    let source = LiveReplica(.wmd)
    try source.write("a\n", peer: 111)
    let base = source.versionVector
    try source.write("a\n\nb\n", peer: 112)
    let tail = try #require(try source.updates(since: base))
    #expect(throws: LiveError.missingDependencies) { try LiveReplica(.wmd).importUpdate(tail) }
  }

  @Test func syntaxErrorsSurfaceFromMerge() {
    #expect(throws: LiveError.syntax(LiveSyntaxError(line: 1, reason: WmdSyntaxError.Problem.quote.description))) {
      try LiveReplica(.wmd).merge(text: "> no\n", base: nil, peer: 113)
    }
  }

  @Test func mergeLeavesTheReplicaAsItWas() throws {
    let live = LiveReplica(.wmd)
    try live.write("a\n", peer: 114)
    let update = try #require(try live.merge(text: "a\n\nb\n", base: nil, peer: 115)?.update)
    #expect(live.text == "a\n")
    try live.importUpdate(update)
    #expect(live.text == "a\n\nb\n")
  }

  @Test func severalBlocksChangedInARowEachStayInTheirContainer() throws {
    let live = LiveReplica(.wmd)
    try live.write("alpha one\n\nbravo two\n\ncharlie three\n\ndelta four\n\necho five\n", peer: 116)
    let agentRead = live.frontiers
    let human = try Self.client(of: live)
    try live.importUpdate(human.type { try text($0, 2).insert(pos: 0, s: "typed ") })
    try live.write("alpha one\n\nbravo 2\n\ncharlie 3\n\ndelta 4\n\necho five\n", base: agentRead, peer: 117)
    #expect(live.text == "alpha one\n\nbravo 2\n\ntyped charlie 3\n\ndelta 4\n\necho five\n")
  }

  /// A person pressed Enter after B and types into the empty paragraph while the agent edits C.
  @Test func anEmptyParagraphTheAgentNeverSawIsLeftAlone() throws {
    let live = LiveReplica(.wmd)
    try live.write("Apple\n\nBanana split\n\nCherry pie recipe\n", peer: 118)
    let human = try Self.client(of: live)
    try live.importUpdate(human.type { list in
      let empty = try list.insertMapContainer(pos: 2, child: LoroMap())
      try empty.insert(key: "kind", v: "paragraph")
      _ = try empty.getOrCreateTextContainer(key: "text", child: LoroText())
    })
    let agentRead = live.frontiers
    #expect(live.text == "Apple\n\nBanana split\n\nCherry pie recipe\n")
    try live.importUpdate(human.type { try text($0, 2).insert(pos: 0, s: "hello") })
    let agentUpdate = try #require(try live.write("Apple\n\nBanana split\n\nCherry pie recipes\n", base: agentRead, peer: 119))
    #expect(live.text == "Apple\n\nBanana split\n\nhello\n\nCherry pie recipes\n")
    try human.importUpdate(agentUpdate)
    #expect(human.text == live.text)
  }

  @Test func deletingOneBlockAndEditingTheNextKeepsTypingInTheEditedOne() throws {
    let live = LiveReplica(.wmd)
    try live.write("Apple\n\nBanana split\n\nCherry pie recipe\n\nDate\n", peer: 120)
    let agentRead = live.frontiers
    let human = try Self.client(of: live)
    try live.importUpdate(human.type { try text($0, 2).insert(pos: 0, s: "My ") })
    try live.write("Apple\n\nCherry pie recipes\n\nDate\n", base: agentRead, peer: 121)
    #expect(live.text == "Apple\n\nMy Cherry pie recipes\n\nDate\n")
  }

  @Test func aListItemWithABlankLineStaysWritable() throws {
    let live = LiveReplica(.wmd)
    try live.write("- one\n    - two\n", peer: 122)
    try live.importUpdate(live.type { list in
      try text(list, 0).insert(pos: 3, s: "\n\nmore")
      try text(list, 1).insert(pos: 3, s: "\n\n\nnested")
    })
    let markdown = live.text
    #expect(markdown == "- one\n\n    more\n    - two\n\n\n        nested\n")
    #expect(try live.merge(text: markdown, base: nil, peer: 123) == nil)
    try live.write(markdown.replacing("more", with: "most"), peer: 124)
    #expect(live.text == "- one\n\n    most\n    - two\n\n\n        nested\n")
  }
}
