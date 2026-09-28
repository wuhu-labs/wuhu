import Foundation
import SpaceContract
import Testing

private struct Vectors: Decodable {
  struct Accepted: Decodable {
    struct Destination: Decodable {
      let kind: String
      let id: String?
      let path: String?
    }

    let spelling: String
    let contextHost: String?
    let host: String
    let destination: Destination
    let query: String?
    let fragment: String?
    let https: String
    let wuhu: String
  }

  struct Origin: Decodable {
    let origin: String
    let host: String?
  }

  struct ContextualRejection: Decodable {
    let spelling: String
    let contextHost: String
  }

  let accepted: [Accepted]
  let rejected: [String]
  let contextual: [Accepted]
  let contextualRejected: [ContextualRejection]
  let origins: [Origin]

  static let shared: Vectors = {
    let file = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("contract/space-url-vectors.json")
    return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
  }()
}

@Suite struct SpaceURLTests {
  @Test func acceptedSpellingsParseAndFormatBothSchemes() throws {
    for vector in Vectors.shared.accepted + Vectors.shared.contextual {
      let url = try #require(SpaceURL(vector.spelling, contextHost: vector.contextHost), "\(vector.spelling)")
      let destination: SpaceURL.Destination = switch vector.destination.kind {
      case "session": .session(try #require(vector.destination.id))
      case "conversation": .conversation(try #require(vector.destination.id))
      default: .path(try #require(vector.destination.path))
      }
      #expect(
        url == SpaceURL(
          host: vector.host,
          destination: destination,
          percentEncodedQuery: vector.query,
          percentEncodedFragment: vector.fragment,
        ),
      )
      #expect(url.formatted(.https) == vector.https)
      #expect(url.formatted(.wuhu) == vector.wuhu)
      #expect(SpaceURL(vector.https) == url)
      #expect(SpaceURL(vector.wuhu) == url)
    }
  }

  @Test func malformedAndRemovedSpellingsAreRejected() {
    for spelling in Vectors.shared.rejected {
      #expect(SpaceURL(spelling) == nil, "\(spelling)")
    }
  }

  @Test func aHostlessLinkNeedsTheHostOfTheSpaceItLivesIn() {
    for vector in Vectors.shared.contextual where vector.contextHost != nil && !vector.spelling.contains("://") {
      #expect(SpaceURL(vector.spelling) == nil, "\(vector.spelling)")
    }
    for vector in Vectors.shared.contextualRejected {
      #expect(SpaceURL(vector.spelling, contextHost: vector.contextHost) == nil, "\(vector.spelling)")
    }
  }

  @Test func anOriginNamesItsHost() {
    for vector in Vectors.shared.origins {
      #expect(SpaceURL.host(origin: vector.origin) == vector.host, "\(vector.origin)")
    }
  }

  @Test func aBuiltURLHoldsTheSameGrammarAsAParsedOne() throws {
    #expect(SpaceURL(host: "Box.Local:443", destination: .path("/x"))?.host == "box.local")
    let session = try #require(SpaceURL(host: "h", destination: .session("a b")))
    #expect(SpaceURL(session.formatted(.wuhu)) == session)
    #expect(SpaceURL(host: "", destination: .path("/")) == nil)
    #expect(SpaceURL(host: "system", destination: .path("/x")) == nil)
    #expect(SpaceURL(host: "user@h", destination: .path("/")) == nil)
    #expect(SpaceURL(host: "h", destination: .path("/a/../b")) == nil)
    #expect(SpaceURL(host: "h", destination: .path("a")) == nil)
    #expect(SpaceURL(host: "h", destination: .path("/a/")) == nil)
    #expect(SpaceURL(host: "h", destination: .path("/_/sessions/x")) == nil)
    #expect(SpaceURL(host: "h", destination: .path("/"), percentEncodedQuery: "a#b") == nil)
  }

  @Test func destinationsResolveFromAPlainPath() {
    #expect(SpaceURL.Destination(percentEncodedPath: "/_/conversations/c1") == .conversation("c1"))
    #expect(SpaceURL.Destination(percentEncodedPath: "/a%20b.md") == .path("/a b.md"))
    #expect(SpaceURL.Destination(percentEncodedPath: "a.md") == nil)
    #expect(SpaceURL.Destination.path("/").percentEncodedPath == "/")
  }
}
