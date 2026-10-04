import Credentials
import Dependencies
import Fetch
import Foundation
@testable import InferenceKit
import Testing

@Suite struct AudioDurationTests {
  @Test func mp3ReadsCompleteFrameTiming() {
    let frame = Data([0xFF, 0xFB, 0x90, 0x00]) + Data(repeating: 0, count: 413)
    let duration = AudioDuration.seconds(.init(bytes: frame + frame, mediaType: .mpeg))
    #expect(duration == 2304.0 / 44100)
    #expect(AudioDuration.seconds(.init(bytes: Data(frame.prefix(20)), mediaType: .mpeg)) == nil)
  }

  @Test func mp4ReadsNestedMovieTiming() {
    func atom(_ name: String, _ payload: Data) -> Data {
      let size = UInt32(payload.count + 8)
      return Data((0 ..< 4).reversed().map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) }) + Data(name.utf8) + payload
    }
    let header = Data(repeating: 0, count: 12) + Data([0, 0, 3, 0xE8, 0, 0, 5, 0xDC])
    let clip = AudioClip(bytes: atom("moov", atom("mvhd", header)), mediaType: .m4a)
    #expect(AudioDuration.seconds(clip) == 1.5)
    #expect(AudioDuration.seconds(.init(bytes: Data(clip.bytes.prefix(12)), mediaType: .mp4)) == nil)
  }

  @Test func webmReadsDurationOrLiveBlockTiming() {
    let floating = Double(1500).bitPattern
    let info = Data([0x15, 0x49, 0xA9, 0x66, 0x8B, 0x44, 0x89, 0x88]) + Data((0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: floating >> ($0 * 8)) })
    #expect(AudioDuration.seconds(.init(bytes: info, mediaType: .webm)) == 1.5)
    let cluster = Data([0x1F, 0x43, 0xB6, 0x75, 0x8B, 0xE7, 0x82, 0x07, 0xD0, 0xA3, 0x85, 0x81, 0, 0, 0x80, 0])
    #expect(AudioDuration.seconds(.init(bytes: cluster, mediaType: .webm)) == 2.12)
  }

  @Test(arguments: AudioMediaType.allCases)
  func invalidContainersHaveNoTiming(mediaType: AudioMediaType) {
    #expect(AudioDuration.seconds(.init(bytes: Data("not audio".utf8), mediaType: mediaType)) == nil)
  }

  @Test func capabilityLoadObservesChangedActiveWithoutDiscardingVariants() async throws {
    let current = LockIsolated("brave")
    let configuration: @Sendable (String) async throws -> Data? = { path in
      guard path == CapabilitiesDocument.spacePath else { return nil }
      return Data("{\"web_search\":{\"active\":\"\(current.value)\",\"providers\":{\"brave\":{\"dialect\":\"brave\"},\"exa\":{\"dialect\":\"exa\"}}}}".utf8)
    }
    let seen = LockIsolated<[String]>([])
    try await withDependencies {
      $0.fetch = FetchClient { request in
        seen.withValue { $0.append(request.url.host ?? "") }
        return Response(status: .ok, body: .string("{}"))
      }
    } operation: {
      let first = try await CapabilityClient.load(read: configuration, credentials: .init { _ in .apiKey("synthetic") })
      #expect(try await first.search("moon").provider == "brave")
      current.setValue("exa")
      let second = try await CapabilityClient.load(read: configuration, credentials: .init { _ in .apiKey("synthetic") })
      #expect(try await second.search("moon").provider == "exa")
      #expect(try await second.search("moon", options: .init(provider: "brave")).provider == "brave")
    }
    #expect(seen.value == ["api.search.brave.com", "api.exa.ai", "api.search.brave.com"])
  }
}
