#if canImport(ImageIO)
  import CoreGraphics
  import ImageIO
#endif
import Foundation
import SessionDomain
import SpaceContract
@testable import SpaceCore
import Testing

@Suite struct ImageFittingTests {
  @Test func `an image within the limits goes out byte for byte`() throws {
    let png = try #require(Self.png(width: 64, height: 32))
    #expect(ImageFitting.fit(png, mimeType: "image/png", limits: .claude) == .image(png, mimeType: "image/png"))
  }

  @Test func `bytes no codec can size are left for the provider`() {
    let opaque = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
    #expect(ImageFitting.fit(opaque, mimeType: "image/png", limits: .claude) == .image(opaque, mimeType: "image/png"))
  }

  @Test func `an oversized image that cannot be decoded becomes a line`() {
    // A png header declaring 6000x4000 with no image data behind it.
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
      0,
      0,
      0x17,
      0x70,
      0,
      0,
      0x0F,
      0xA0,
    ])
    guard case let .note(note) = ImageFitting.fit(header, mimeType: "image/png", limits: .claude) else {
      Issue.record("an image nobody can scale must not reach the provider")
      return
    }
    #expect(note.contains("6000x4000 px"))
    #expect(note.contains("2576 px on the long edge"))
  }

  #if canImport(ImageIO)
    @Test func `a 6000 px image is scaled to what each model takes`() throws {
      let png = try #require(Self.png(width: 6000, height: 4000))
      for (limits, patch) in [(ImageLimits.claude, 28), (.openAI, 32), (ImageLimits.claude.forRequest(imageCount: 21), 28)] {
        guard case let .image(data, _) = ImageFitting.fit(png, mimeType: "image/png", limits: limits) else {
          Issue.record("the image must be scaled, not dropped")
          continue
        }
        let size = try #require(ImageMedia.pixelSize(ofBytes: data))
        #expect(size.longEdge <= limits.maxLongEdge)
        #expect(((size.width + patch - 1) / patch) * ((size.height + patch - 1) / patch) <= limits.maxPatches)
        #expect(data.count <= limits.maxBytes)
      }
    }

    @Test func `an image past the byte budget is re-encoded under it`() throws {
      let png = try #require(Self.png(width: 2000, height: 2000, noise: true))
      #expect(png.count > ImageMedia.maxBytes)
      guard case let .image(data, _) = ImageFitting.fit(png, mimeType: "image/png", limits: .claude) else {
        Issue.record("the image must be re-encoded, not dropped")
        return
      }
      #expect(data.count <= ImageMedia.maxBytes)
    }

    @Test func `many mid-size images in one request stay under its byte budget`() throws {
      // Twelve noisy 1200 px screenshots of about 4 MB each: 50 MB in all.
      let png = try #require(Self.png(width: 1200, height: 1200, noise: true))
      #expect(png.count > 4_000_000)
      for base in [ImageLimits.openAI, .claude] {
        let budget = try #require(base.requestBytes)
        let limits = base.forRequest(imageCount: 12)
        var total = 0
        for _ in 0 ..< 12 {
          guard case let .image(data, _) = ImageFitting.fit(png, mimeType: "image/png", limits: limits) else {
            Issue.record("each image must be re-encoded, not dropped")
            return
          }
          total += data.count
        }
        #expect(total <= budget)
      }
    }
  #endif

  static func png(width: Int, height: Int, noise: Bool = false) -> Data? {
    #if canImport(ImageIO)
      guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
      ) else { return nil }
      if noise, let pixels = context.data?.assumingMemoryBound(to: UInt32.self) {
        var state: UInt32 = 2_463_534_242
        for index in 0 ..< context.bytesPerRow / 4 * height {
          state ^= state << 13
          state ^= state >> 17
          state ^= state << 5
          pixels[index] = state
        }
      } else {
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      }
      guard let image = context.makeImage() else { return nil }
      let output = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return output as Data
    #else
      // A 1x1 png, enough for the pass-through checks where no codec exists.
      guard width <= 64 else { return nil }
      return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
    #endif
  }
}
