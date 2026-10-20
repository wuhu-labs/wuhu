import DeterministicDependencies
import Foundation
import struct SpaceContract.GroupID
@testable import SpaceCore
import Testing

// The vectors the clients build `viewing` from (SpaceContract
// `GroupID.viewing`, web lib/viewing.ts): every spelling they emit is one the
// server stores as sent, the root they leave unnamed parses (a send naming it
// is refused for having no entry, MessageViewingRouteTests), and every path
// they leave out is one it refuses.
@Suite(.deterministicDependencies) struct ViewingVectorTests {
  private struct Vectors: Decodable {
    struct Spelled: Decodable {
      let viewing: String
    }

    struct Cases: Decodable {
      let cases: [Spelled]
    }

    struct Paths: Decodable {
      let paths: [String]
    }

    let named: Cases
    let unnamed: Cases
    let omitted: Paths
  }

  private let vectors: Vectors = {
    let file = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("SpaceContract/Tests/contract/viewing-vectors.json")
    return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
  }()

  @Test func aSpellingAClientEmitsIsStoredAsSent() throws {
    for vector in vectors.named.cases {
      #expect(try Viewing(vector.viewing, actingIn: .shared).stored == vector.viewing)
    }
  }

  @Test func theRootAClientLeavesUnnamedParses() throws {
    for vector in vectors.unnamed.cases {
      #expect(try Viewing(vector.viewing, actingIn: .shared).stored == vector.viewing)
    }
  }

  @Test func aPathAClientOmitsIsRefused() {
    for path in vectors.omitted.paths {
      #expect(throws: ViewingError.self, "\(path)") {
        _ = try Viewing(GroupID.shared.address(path), actingIn: .shared)
      }
    }
  }
}
