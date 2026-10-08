#if canImport(ImageIO)
  import CoreGraphics
  import ImageIO
#endif
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import CImageCodec
#endif
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

  @Test func `an iPhone screenshot fits the long edge`() throws {
    let png = try #require(Self.png(width: 1320, height: 2868))
    guard case let .image(data, mime) = ImageFitting.fit(png, mimeType: "image/png", limits: .claude) else {
      Issue.record("the screenshot must be scaled"); return
    }
    let size = try #require(ImageMedia.pixelSize(ofBytes: data))
    #expect(size.height == 2576)
    #expect((1185 ... 1186).contains(size.width))
    #expect(mime == "image/png")
    #expect(data.count <= ImageLimits.claude.maxBytes)
  }

  @Test func `a JPEG past the byte budget stays JPEG`() throws {
    let source = try #require(Self.png(width: 640, height: 480, noise: true))
    let jpeg = try #require(Self.jpeg(source))
    var limits = ImageLimits.claude
    limits.maxBytes = 30000
    #expect(jpeg.count > limits.maxBytes)
    guard case let .image(data, mime) = ImageFitting.fit(jpeg, mimeType: "image/jpeg", limits: limits) else {
      Issue.record("JPEG must be fitted"); return
    }
    #expect(mime == "image/jpeg")
    #expect(data.count <= limits.maxBytes)
    #expect(ImageMedia.pixelSize(ofBytes: data) != nil)
  }

  @Test func `truncated oversized images are explicitly refused`() throws {
    let png = try #require(Self.png(width: 1320, height: 2868))
    let jpeg = try #require(Self.jpeg(png))
    let jpegBytes = [UInt8](jpeg)
    let scan = try #require((2 ..< jpegBytes.count - 1).first { jpegBytes[$0] == 0xFF && jpegBytes[$0 + 1] == 0xDA })
    for (source, mime) in [(Data(png.prefix(24)), "image/png"), (Data(jpeg.prefix(scan + 2)), "image/jpeg")] {
      guard case let .note(text) = ImageFitting.fit(source, mimeType: mime, limits: .claude) else {
        Issue.record("truncated image must be refused"); continue
      }
      #expect(text.contains("this server could not scale it"))
    }
  }

  @Test func `JPEG EXIF orientation is applied when fitting`() throws {
    let png = try #require(Self.png(width: 80, height: 40))
    let jpeg = try #require(Self.jpeg(png))
    // APP1 with a little-endian TIFF orientation of 6 (rotate clockwise).
    let exif: [UInt8] = [
      0xFF,
      0xE1,
      0,
      34,
      69,
      120,
      105,
      102,
      0,
      0,
      73,
      73,
      42,
      0,
      8,
      0,
      0,
      0,
      1,
      0,
      18,
      1,
      3,
      0,
      1,
      0,
      0,
      0,
      6,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]
    var oriented = Data(jpeg.prefix(2)); oriented.append(contentsOf: exif); oriented.append(jpeg.dropFirst(2))
    var limits = ImageLimits.claude; limits.maxLongEdge = 32
    guard case let .image(data, _) = ImageFitting.fit(oriented, mimeType: "image/jpeg", limits: limits) else {
      Issue.record("oriented image must be fitted"); return
    }
    #expect(ImageMedia.pixelSize(ofBytes: data) == PixelSize(width: 16, height: 32))
  }

  @Test func `alpha palette grayscale and 16 bit PNGs can be fitted`() throws {
    let fixtures = [
      "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEUlEQVR4nGP4z8DQgIwZ0AUA0Y4L+S7KWhwAAAAASUVORK5CYII=",
      "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAMAAABIdo1RAAAABlBMVEX/AAAA/wDSh+9xAAAAAnRSTlOA/2ASuv4AAAAOSURBVHicY2BgBEIQAQAAHAAF+bbNWAAAAABJRU5ErkJggg==",
      "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACEAAAAAAKU/78AAAAD0lEQVR4nGNoYIBABhgDACYSBAFQcYqWAAAAAElFTkSuQmCC",
      "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAAAAABawyK/AAAADklEQVR4nGNoAAIGEAEAFAoEAeiOg+cAAAAASUVORK5CYII=",
    ]
    var limits = ImageLimits.claude; limits.maxLongEdge = 2
    for encoded in fixtures {
      let png = try #require(Data(base64Encoded: encoded))
      guard case let .image(data, mime) = ImageFitting.fit(png, mimeType: "image/png", limits: limits) else {
        Issue.record("PNG subtype must be fitted"); continue
      }
      #expect(mime == "image/png")
      #expect(ImageMedia.pixelSize(ofBytes: data) == PixelSize(width: 2, height: 1))
      #if os(Linux)
        let decoded = try #require(LinuxImage(data))
        if encoded == fixtures[0] { #expect(decoded.pixels[3] == 128) }
      #endif
    }
  }

  @Test func `a pixel bomb header is explicitly refused`() throws {
    let bomb = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgABhqAAAYagCAYAAACoUgvIAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII="))
    guard case let .note(note) = ImageFitting.fit(bomb, mimeType: "image/png", limits: .claude) else {
      Issue.record("pixel bomb must be refused before decoding"); return
    }
    #expect(note.contains("100000x100000 px"))
  }

  @Test func `a byte budget too small for any encoding is an explicit refusal`() throws {
    let png = try #require(Self.png(width: 64, height: 32))
    var limits = ImageLimits.claude; limits.maxBytes = 1
    guard case let .note(note) = ImageFitting.fit(png, mimeType: "image/png", limits: limits) else {
      Issue.record("no encoding fits one byte"); return
    }
    #expect(note.contains("this server could not scale it"))
  }

  #if os(Linux)
    @Test func `JPEGs truncated in their scan data are refused`() throws {
      let png = try #require(Self.png(width: 1320, height: 2868))
      let jpeg = try #require(Self.jpeg(png))
      guard case .note = ImageFitting.fit(Data(jpeg.prefix(jpeg.count / 2)), mimeType: "image/jpeg", limits: .claude) else {
        Issue.record("truncated JPEG must not be silently repaired"); return
      }
    }

    @Test func `all EXIF orientations and malformed metadata are handled`() throws {
      let png = try #require(Self.png(width: 80, height: 40))
      let jpeg = try #require(Self.jpeg(png))
      for orientation: UInt8 in 1 ... 8 {
        let exif: [UInt8] = [
          0xFF,
          0xE1,
          0,
          34,
          69,
          120,
          105,
          102,
          0,
          0,
          73,
          73,
          42,
          0,
          8,
          0,
          0,
          0,
          1,
          0,
          18,
          1,
          3,
          0,
          1,
          0,
          0,
          0,
          orientation,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        ]
        var data = Data(jpeg.prefix(2)); data.append(contentsOf: exif); data.append(jpeg.dropFirst(2))
        #expect(ImageOrientation.read(data) == Int(orientation))
        let image = try #require(LinuxImage(data))
        #expect(image.size == (orientation >= 5 ? PixelSize(width: 40, height: 80) : PixelSize(width: 80, height: 40)))
        for count in 0 ..< exif.count {
          _ = ImageOrientation.read(Data(data.prefix(count)))
        }
      }
    }
  #endif

  static func jpeg(_ png: Data) -> Data? {
    #if canImport(ImageIO)
      guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
      let output = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
      CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return output as Data
    #elseif os(Linux)
      return LinuxImage(png)?.encoded(png: false, quality: 100)
    #else
      return nil
    #endif
  }

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
    #elseif os(Linux)
      var pixels = [UInt8](repeating: 255, count: width * height * 4)
      var state: UInt32 = 2_463_534_242
      for index in stride(from: 0, to: pixels.count, by: 4) {
        if noise {
          state ^= state << 13
          state ^= state >> 17
          state ^= state << 5
          pixels[index] = UInt8(truncatingIfNeeded: state)
          pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 8)
          pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 16)
        } else {
          pixels[index] = 51; pixels[index + 1] = 102; pixels[index + 2] = 204
        }
      }
      var count = 0
      guard let output = pixels.withUnsafeBufferPointer({ image_encode_png($0.baseAddress, Int32(width), Int32(height), &count) }) else { return nil }
      defer { image_codec_free(output) }
      return Data(bytes: output, count: count)
    #else
      return nil
    #endif
  }
}
