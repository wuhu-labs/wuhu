#if os(Linux)
  import CImageCodec
  #if canImport(FoundationEssentials)
    import FoundationEssentials
  #else
    import Foundation
  #endif
  import struct SpaceContract.PixelSize

  struct LinuxImage {
    static let maxPixels = Int(IMAGE_CODEC_MAX_PIXELS)
    var pixels: [UInt8]
    var size: PixelSize
    var isPNG: Bool

    init?(_ data: Data) {
      var decoded = DecodedImage()
      guard data.withUnsafeBytes({ bytes in
        image_decode(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, Self.maxPixels, &decoded)
      }) != 0, let pointer = decoded.pixels else { return nil }
      let width = Int(decoded.width), height = Int(decoded.height)
      pixels = Array(UnsafeBufferPointer(start: pointer, count: width * height * 4))
      image_codec_free(pointer)
      size = PixelSize(width: width, height: height)
      isPNG = decoded.is_png != 0
      orient(ImageOrientation.read(data))
    }

    func resized(to target: PixelSize) -> LinuxImage {
      guard target != size else { return self }
      var output = [UInt8](repeating: 0, count: target.width * target.height * 4)
      let xScale = Double(size.width) / Double(target.width)
      let yScale = Double(size.height) / Double(target.height)
      pixels.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
          for y in 0 ..< target.height {
            let sourceY = max(0, (Double(y) + 0.5) * yScale - 0.5)
            let y0 = min(size.height - 1, Int(sourceY)), y1 = min(size.height - 1, y0 + 1)
            let dy = sourceY - Double(y0)
            for x in 0 ..< target.width {
              let sourceX = max(0, (Double(x) + 0.5) * xScale - 0.5)
              let x0 = min(size.width - 1, Int(sourceX)), x1 = min(size.width - 1, x0 + 1)
              let dx = sourceX - Double(x0)
              let a = (y0 * size.width + x0) * 4, b = (y0 * size.width + x1) * 4
              let c = (y1 * size.width + x0) * 4, d = (y1 * size.width + x1) * 4
              let wa = (1 - dx) * (1 - dy), wb = dx * (1 - dy), wc = (1 - dx) * dy, wd = dx * dy
              let aa = Double(source[a + 3]) * wa, ab = Double(source[b + 3]) * wb
              let ac = Double(source[c + 3]) * wc, ad = Double(source[d + 3]) * wd
              let alpha = aa + ab + ac + ad
              let index = (y * target.width + x) * 4
              destination[index + 3] = UInt8(clamping: Int(alpha.rounded()))
              for channel in 0 ..< 3 {
                let value = Double(source[a + channel]) * aa + Double(source[b + channel]) * ab
                  + Double(source[c + channel]) * ac + Double(source[d + channel]) * ad
                destination[index + channel] = alpha > 0 ? UInt8(clamping: Int((value / alpha).rounded())) : 0
              }
            }
          }
        }
      }
      return LinuxImage(pixels: output, size: target, isPNG: isPNG)
    }

    func encoded(png: Bool, quality: Int = 85) -> Data? {
      var input = pixels
      if !png, stride(from: 3, to: input.count, by: 4).contains(where: { input[$0] != 255 }) {
        for index in stride(from: 0, to: input.count, by: 4) {
          let alpha = Int(input[index + 3])
          for channel in 0 ..< 3 {
            input[index + channel] = UInt8((Int(input[index + channel]) * alpha + 255 * (255 - alpha) + 127) / 255)
          }
          input[index + 3] = 255
        }
      }
      var count = 0
      let output = input.withUnsafeBufferPointer { bytes in
        png
          ? image_encode_png(bytes.baseAddress, Int32(size.width), Int32(size.height), &count)
          : image_encode_jpeg(bytes.baseAddress, Int32(size.width), Int32(size.height), Int32(quality), &count)
      }
      guard let output else { return nil }
      defer { image_codec_free(output) }
      return Data(bytes: output, count: count)
    }

    private init(pixels: [UInt8], size: PixelSize, isPNG: Bool) {
      self.pixels = pixels
      self.size = size
      self.isPNG = isPNG
    }

    private mutating func orient(_ orientation: Int) {
      guard (2 ... 8).contains(orientation) else { return }
      let width = size.width, height = size.height
      let swapped = orientation >= 5
      let target = PixelSize(width: swapped ? height : width, height: swapped ? width : height)
      var output = [UInt8](repeating: 0, count: pixels.count)
      for y in 0 ..< height {
        for x in 0 ..< width {
          let destination: (Int, Int)
          switch orientation {
          case 2: destination = (width - 1 - x, y)
          case 3: destination = (width - 1 - x, height - 1 - y)
          case 4: destination = (x, height - 1 - y)
          case 5: destination = (y, x)
          case 6: destination = (height - 1 - y, x)
          case 7: destination = (height - 1 - y, width - 1 - x)
          default: destination = (y, width - 1 - x)
          }
          let source = (y * width + x) * 4
          let dest = (destination.1 * target.width + destination.0) * 4
          for channel in 0 ..< 4 { output[dest + channel] = pixels[source + channel] }
        }
      }
      pixels = output
      size = target
    }
  }
#endif
