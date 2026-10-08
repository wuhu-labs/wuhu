#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceContract
@testable import SpaceCore
import Testing
#if os(Linux)
  import CImageCodec
#endif

@Suite struct ImageCodecSecurityTests {
  @Test func `absurd PNG header dimensions are refused without overflowing`() {
    let header = Data([
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0,
      0,
      0,
      13,
      0x49,
      0x48,
      0x44,
      0x52,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
    ])
    guard case let .note(note) = ImageFitting.fit(header, mimeType: "image/png", limits: .claude) else {
      Issue.record("absurd header must be refused"); return
    }
    #expect(note.contains("4294967295x4294967295 px"))
    let size = ImageLimits.claude.fitted(PixelSize(width: Int(UInt32.max), height: Int(UInt32.max)))
    #expect(size.longEdge <= ImageLimits.claude.maxLongEdge)
  }

  @Test func `PNG EXIF orientation is applied when fitting`() throws {
    let png = try Self.fixture("oriented.png")
    var limits = ImageLimits.claude; limits.maxLongEdge = 32
    guard case let .image(data, _) = ImageFitting.fit(png, mimeType: "image/png", limits: limits) else {
      Issue.record("PNG orientation must be fitted"); return
    }
    #expect(ImageMedia.pixelSize(ofBytes: data) == PixelSize(width: 16, height: 32))
  }

  #if os(Linux)
    @Test func `compressed PNG text metadata is skipped before decode`() throws {
      // 64 zTXt/iTXt chunks expand to 256 MiB; none is needed to fit these 2048 pixels.
      let bomb = try Self.fixture("text-bomb.png")
      #expect(bomb.count < 300_000)
      let decoded = try #require(LinuxImage(bomb))
      #expect(decoded.size == PixelSize(width: 64, height: 32))
      #expect(Array(decoded.pixels.prefix(4)) == [51, 102, 204, 255])
      var limits = ImageLimits.claude; limits.maxLongEdge = 16
      guard case let .image(data, _) = ImageFitting.fit(bomb, mimeType: "image/png", limits: limits) else {
        Issue.record("irrelevant metadata must not stop pixel fitting"); return
      }
      #expect(ImageMedia.pixelSize(ofBytes: data) == PixelSize(width: 16, height: 8))
      #expect(data.count < 1000)
    }

    @Test func `a PNG missing IEND is refused`() throws {
      let png = try #require(ImageFittingTests.png(width: 1320, height: 2868))
      let truncated = Data(png.dropLast(12))
      #expect(LinuxImage(truncated) == nil)
      guard case .note = ImageFitting.fit(truncated, mimeType: "image/png", limits: .claude) else {
        Issue.record("a missing IEND must not be silently repaired"); return
      }
    }

    @Test func `over budget transparent PNG is composited on white as JPEG`() throws {
      var pixels = [UInt8](repeating: 0, count: 100 * 100 * 4)
      var state: UInt32 = 2_463_534_242
      for index in stride(from: 0, to: pixels.count, by: 4) {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5
        for channel in 0 ..< 3 { pixels[index + channel] = UInt8(truncatingIfNeeded: state >> (channel * 8)) }
      }
      var count = 0
      let bytes = try #require(pixels.withUnsafeBufferPointer { image_encode_png($0.baseAddress, 100, 100, &count) })
      defer { image_codec_free(bytes) }
      let png = Data(bytes: bytes, count: count)
      var limits = ImageLimits.claude; limits.maxBytes = 2000
      #expect(png.count > limits.maxBytes)
      guard case let .image(data, mime) = ImageFitting.fit(png, mimeType: "image/png", limits: limits) else {
        Issue.record("transparent PNG must fit as JPEG"); return
      }
      #expect(mime == "image/jpeg")
      #expect(data.count <= limits.maxBytes)
      let decoded = try #require(LinuxImage(data))
      #expect(decoded.size == PixelSize(width: 100, height: 100))
      #expect(decoded.pixels.allSatisfy { $0 >= 250 })
    }

    @Test func `C encoders reject pixel bombs before reading the input buffer`() {
      var count = 0
      #expect(image_encode_png(nil, 10000, 10000, &count) == nil)
      #expect(image_encode_jpeg(nil, 10000, 10000, 85, &count) == nil)
      #expect(image_encode_png(nil, .max, .max, &count) == nil)
      #expect(image_encode_jpeg(nil, .max, .max, 85, &count) == nil)
      #expect(count == 0)
    }
  #endif

  static func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/image-fitting/\(name)"))
  }
}
