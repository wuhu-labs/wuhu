import Credentials
import Dependencies
import Fetch
import Foundation
@testable import InferenceKit
import Testing

@Suite struct MP4DurationTests {
  private static func big(_ value: UInt64, count: Int = 4) -> Data {
    Data((0 ..< count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }

  private static func atom(_ name: String, _ payload: Data) -> Data {
    big(UInt64(payload.count + 8)) + Data(name.utf8) + payload
  }

  private static func full(_ flags: UInt64 = 0, version: UInt8 = 0) -> Data {
    Data([version]) + big(flags, count: 3)
  }

  private static func movie(defaultDuration: UInt64 = 0, scale: UInt64 = 1000) -> Data {
    let header = full() + big(0) + big(0) + big(scale) + big(0)
    let track = atom("tkhd", full() + big(0) + big(0) + big(1)) + atom("mdia", atom("mdhd", header))
    let defaults = atom("trex", full() + big(1) + big(1) + big(defaultDuration) + big(1) + big(0))
    return atom("moov", atom("mvhd", header) + atom("trak", track) + atom("mvex", defaults))
  }

  private static func fragment(defaultDuration: UInt64? = nil, start: UInt64? = 0, runs: [Data], decodeVersion: UInt8 = 1) -> Data {
    let header = full(defaultDuration == nil ? 0x020000 : 0x020008) + big(1) + (defaultDuration.map { big($0) } ?? Data())
    let decode = start.map { atom("tfdt", full(version: decodeVersion) + big($0, count: decodeVersion == 1 ? 8 : 4)) } ?? Data()
    return atom("moof", atom("traf", atom("tfhd", header) + decode + runs.reduce(Data()) { $0 + atom("trun", $1) })) + atom("mdat", Data([0]))
  }

  private static func seconds(_ bytes: Data) -> Double? {
    AudioDuration.seconds(.init(bytes: bytes, mediaType: .mp4))
  }

  @Test func explicitSamplesAndDefaultsEstablishFragmentDuration() {
    let explicit = Self.full(0xF05) + [UInt64(2), 0, 0, 400, 1, 0, 100, 600, 1, 0, 100].reduce(Data()) { $0 + Self.big($1) }
    let bytes = Self.movie() + Self.fragment(runs: [explicit])
    #expect(Self.seconds(bytes) == 1.1)
    let defaults = Self.movie(defaultDuration: 500) + Self.fragment(runs: [Self.full() + Self.big(3)], decodeVersion: 0)
    #expect(Self.seconds(defaults) == 1.5)
    let override = Self.movie(defaultDuration: 999) + Self.fragment(defaultDuration: 100, runs: [Self.full() + Self.big(3), Self.full() + Self.big(2)])
    #expect(Self.seconds(override) == 0.5)
  }

  @Test func multipleFragmentsBoundBothTimelineAndAggregateSamples() {
    let first = Self.fragment(defaultDuration: 1000, runs: [Self.full() + Self.big(2)])
    let second = Self.fragment(defaultDuration: 1000, start: 5000, runs: [Self.full() + Self.big(1)])
    #expect(Self.seconds(Self.movie() + first + second) == 6)
    #expect(Self.seconds(Self.movie() + first + first) == 4)
    let signed = Self.full(0x900, version: 1) + Self.big(1) + Self.big(1000) + Self.big(UInt64(UInt32(bitPattern: -200)))
    #expect(Self.seconds(Self.movie() + Self.fragment(runs: [signed])) == 1)
  }

  @Test(arguments: [1, 7200, 7201])
  func zeroMovieHeadersNeverBypassFragmentDurationBound(seconds: Int) async throws {
    let bytes = Self.movie() + Self.fragment(defaultDuration: UInt64(seconds * 1000), runs: [Self.full() + Self.big(1)])
    #expect(Self.seconds(bytes) == Double(seconds))
    let calls = LockIsolated(0)
    let provider = CapabilityClient(document: nil, credentials: .init { _ in .chatGPT(accessToken: "synthetic", accountID: "synthetic") })
    for mediaType in [AudioMediaType.mp4, .m4a] {
      do {
        let reply = try await withDependencies {
          $0.fetch = FetchClient { _ in calls.withValue { $0 += 1 }; return Response(status: .ok, body: .string(#"{"text":"bounded fragment"}"#)) }
        } operation: { try await provider.transcribe(.init(bytes: bytes, mediaType: mediaType)) }
        #expect(seconds <= 7200)
        #expect(reply.text == "bounded fragment")
      } catch let error as CapabilityError {
        #expect(seconds > 7200)
        #expect(error.code == .invalidArgument)
        #expect(error.message.contains("two hours"))
      }
    }
    #expect(calls.value == (seconds <= 7200 ? 2 : 0))
  }

  @Test func decodeTimeAndPresentationOffsetsCannotHideLongFragments() async throws {
    let decode = Self.movie() + Self.fragment(defaultDuration: 1, start: 7_201_000, runs: [Self.full() + Self.big(1)])
    let composition = Self.movie() + Self.fragment(runs: [Self.full(0x900) + Self.big(1) + Self.big(1) + Self.big(7_201_000)])
    #expect(Self.seconds(decode)! > 7200)
    #expect(Self.seconds(composition)! > 7200)
    try await Self.rejectBeforeProviderIO([decode, composition])
  }

  @Test func missingOrMalformedFragmentTimingNeverAuthorizesSpend() async throws {
    let noDuration = Self.movie() + Self.fragment(runs: [Self.full() + Self.big(1)])
    let noDecode = Self.movie() + Self.fragment(defaultDuration: 1, start: nil, runs: [Self.full() + Self.big(1)])
    let truncated = Self.movie() + Self.fragment(runs: [Self.full(0x100) + Self.big(2) + Self.big(1)])
    let noTracks = Self.atom("moov", Self.atom("mvhd", Self.full() + Self.big(0) + Self.big(0) + Self.big(1000) + Self.big(0))) + Self.fragment(defaultDuration: 1000, runs: [Self.full() + Self.big(1)])
    let overflow = Self.movie() + Self.fragment(defaultDuration: 1, start: UInt64.max, runs: [Self.full() + Self.big(1)])
    let badFlags = Self.movie() + Self.fragment(defaultDuration: 1, runs: [Self.full(0x10) + Self.big(1)])
    let values = [noDuration, noDecode, truncated, noTracks, overflow, badFlags, Self.movie()]
    for bytes in values { #expect(Self.seconds(bytes) == nil) }
    try await Self.rejectBeforeProviderIO(values)
  }

  @Test func generatedAACFragmentedContainerHasRecordedDuration() {
    let bytes = Data(base64Encoded: "AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAAAr1tb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAAAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAABv3RyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAVttZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAALuAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAAAAAAAAAAAAAAAFNvdW5kSGFuZGxlcgAAAAEGbWluZgAAABBzbWhkAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAADKc3RibAAAAH5zdHNkAAAAAAAAAAEAAABubXA0YQAAAAAAAAABAAAAAAAAAAAAAQAQAAAAALuAAAAAAAA2ZXNkcwAAAAADgICAJQABAASAgIAXQBUAAAAAAH0AAAB9AAWAgIAFEYhW5QAGgICAAQIAAAAUYnRydAAAAAAAAH0AAAB9AAAAABBzdHRzAAAAAAAAAAAAAAAQc3RzYwAAAAAAAAAAAAAAFHN0c3oAAAAAAAAAAAAAAAAAAAAQc3RjbwAAAAAAAAAAAAAAKG12ZXgAAAAgdHJleAAAAAAAAAABAAAAAQAAAAAAAAAAAAAAAAAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAxAAAAzG1vb2YAAAAQbWZoZAAAAAAAAAABAAAAtHRyYWYAAAAcdGZoZAACADgAAAABAAAEAAAAAI4CAAAAAAAAFHRmZHQBAAAAAAAAAAAAAAAAAAB8dHJ1bgAAAwEAAAANAAAA1AAABAAAAACOAAAEAAAAAJ8AAAQAAAAAOQAABAAAAAA6AAAEAAAAAEAAAAQAAAAARgAABAAAAABHAAAEAAAAAFQAAAQAAAAATgAABAAAAABSAAAEAAAAAFAAAAQAAAAAawAAAuAAAABaAAAEfm1kYXTeAgBMYXZjNjIuMjguMTAxAAJoo1mhKI01h0qZX2+KcR5pe5IkPCJJ//6uSBN0w3NitPWzbXSLq7g7Zo78N7iwVsqa0yUiVc21Gcy0SkSkSJkpEoGBgZEDAxs2bBgZEiRGzZs2iRIpZZbNwBKi4jcESqnI1k2NcIz20VdIzl0FbIzTkqocBpkpyaJrkpauATSU2sldlkurJdQU6b/fzq21q5/28fv51rjV6//i9fv51rjV6//sX+POta1qxtTs26555g1lss9wovf7KBg3QPpQr6UD6fTWYD6fT6UAfT6fTWB9Pp9NdBgB9Pp9NZmwBrnrRYtUn823SIQxM+UTPlEz5fKImD5fLjEwfL5cSYPl8vlFEQA+Xy+XGKIAWXPWcCQkJCQkJCQkJCQkJCTnATbxivrGT+P6fr1xx51OJqaau5G/clqtKgf+G0vufHxmbd9/cD4zAZ9AGT4Az+4HxmMM/uAfxYBwAQQxikJdY57/4//i/8v9/83VzVVxz8dxmO/XdxuJVCKKJa9BjRRRRRRdwiiBRRIRVE/Wt0IKjqJw4AEGMZGirRCHUq5/6f/X/b/2/zdXKlaVTisdlSk3dKgCQkJijbUoJCQlKEhMy9hG3r5TI2sKZbzS3Rte8OkNpPgBBDGRZM0Sh1LOf7//X+f/0/DUqrqV1lSzvusjdqUAYGHd6M9xqy9rYGJH5p1T7FHnPODzqQtAMiKcK9Muq/j4zy5W0GnAAPoxmULdEYdS33/f/6/z/+n1nnaQayTm3rxrm6ySqBrTuvuCw67QyVCMrLtevXrzT9PpmS4Tlr1tc9euSxKSc8EY/A8CiHABADGs5Q0Qh0Yh0YiU/p/4/z/j4uSXRdXiU8DLpSVQLKLOH1gJDY+tt/TVULKj9UUdFHTR0GoMY5tYFZka1FgZYVBhWwNm4884VzKdli1mDnIsQOABBDGo5Q0Qh0Yh0qV/H/4f+X+Ltcq2vH17+ZuO+6yJSlAEIEoldFlpPln9Twr04NFFFFFFERRAkRIDIkBACsszIglAcV6FzhtLq4ZUWvwBBjGs6JE+iMOiEOmed/x/6f9f39i9Ua5tV5bt07ve5KAMKxMLE7TMSgX1O02x+4RqISEhITqkJCbt27lTCTjglKSyMpTJdGO+HrxT8OyitSDgAPwxrOUNEodQYVb/b/p9f+3FNRLVqs1VPKXu6pKoBUTN6ZvRtf6Xk4f5gKBp5555551KnPOedXquZSp/VQJfBAArOgc0O60dYQg03F+5e3ABMDGhaM0RB0JB0JB0Ih0RBKn/j7/4rOOC8kuJI6pq7u5ckExOelUI7eyQxYQVlMtAC2xMPJl/AB6RGWInzA8RHSotsH6g+C2kw2YriI7KK2G5MEmJUd1V8h0nxNcq9B3WObR86knI11S08AFQMYs6Ih6Qgm+e7+ONXd3EktcS3DepNROBnyOn+G4c2fJuy88ObRkzvwTNw5msjuWCFuFzO+mZuFtpDp4CbUzO+7MZ908ELbTjr6ZjQ5mn3TwE3C40+7MaHgAAAENtZnJhAAAAK3RmcmEBAAAAAAAAAQAAAAAAAAABAAAAAAAAAAAAAAAAAAAC2QEBAQAAABBtZnJvAAAAAAAAAEM=")!
    #expect(abs(Self.seconds(bytes)! - 0.2713333333333333) < 0.000001)
  }

  private static func rejectBeforeProviderIO(_ values: [Data]) async throws {
    let calls = LockIsolated(0)
    let provider = CapabilityClient(document: nil, credentials: .init { _ in .chatGPT(accessToken: "synthetic", accountID: "synthetic") })
    for bytes in values {
      do {
        _ = try await withDependencies {
          $0.fetch = FetchClient { _ in calls.withValue { $0 += 1 }; return Response(status: .ok, body: .string(#"{"text":"must not upload"}"#)) }
        } operation: { try await provider.transcribe(.init(bytes: bytes, mediaType: .mp4)) }
        Issue.record("Unbounded fragment was uploaded")
      } catch let error as CapabilityError {
        #expect(error.code == .invalidArgument)
      }
    }
    #expect(calls.value == 0)
  }
}
