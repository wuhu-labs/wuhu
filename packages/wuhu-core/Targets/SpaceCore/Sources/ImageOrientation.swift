#if os(Linux)
  #if canImport(FoundationEssentials)
    import FoundationEssentials
  #else
    import Foundation
  #endif

  enum ImageOrientation {
    static func read(_ data: Data) -> Int {
      let bytes = [UInt8](data)
      if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
        return png(bytes)
      }
      guard bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return 1 }
      var offset = 2
      while offset + 4 <= bytes.count {
        guard bytes[offset] == 0xFF else { return 1 }
        while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
        guard offset < bytes.count else { return 1 }
        let marker = bytes[offset]
        offset += 1
        if marker == 0xDA || marker == 0xD9 { break }
        if marker == 0x01 || (0xD0 ... 0xD7).contains(marker) { continue }
        guard offset + 2 <= bytes.count else { return 1 }
        let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
        guard length >= 2, length <= bytes.count - offset else { return 1 }
        if marker == 0xE1, length >= 8,
           Array(bytes[(offset + 2) ..< (offset + 8)]) == [0x45, 0x78, 0x69, 0x66, 0, 0],
           let orientation = tiff(bytes[(offset + 8) ..< (offset + length)])
        { return orientation }
        offset += length
      }
      return 1
    }

    private static func png(_ bytes: [UInt8]) -> Int {
      var offset = 8
      while bytes.count - offset >= 12 {
        let length = bytes[offset ..< offset + 4].reduce(0) { $0 * 256 + Int($1) }
        guard length <= bytes.count - offset - 12 else { return 1 }
        if Array(bytes[(offset + 4) ..< (offset + 8)]) == [0x65, 0x58, 0x49, 0x66],
           let orientation = tiff(bytes[(offset + 8) ..< (offset + 8 + length)])
        {
          return orientation
        }
        offset += length + 12
      }
      return 1
    }

    private static func tiff(_ bytes: ArraySlice<UInt8>) -> Int? {
      guard bytes.count >= 8 else { return nil }
      let little = bytes[bytes.startIndex] == 0x49 && bytes[bytes.startIndex + 1] == 0x49
      guard little || (bytes[bytes.startIndex] == 0x4D && bytes[bytes.startIndex + 1] == 0x4D) else { return nil }
      func integer(_ offset: Int, _ count: Int) -> Int? {
        guard offset >= 0, offset <= bytes.count - count else { return nil }
        var value = 0
        for i in 0 ..< count {
          value = value * 256 + Int(bytes[bytes.startIndex + offset + (little ? count - i - 1 : i)])
        }
        return value
      }
      guard integer(2, 2) == 42, let start = integer(4, 4), let count = integer(start, 2),
            start <= bytes.count - 2, count <= (bytes.count - start - 2) / 12 else { return nil }
      for index in 0 ..< count {
        let offset = start + 2 + index * 12
        if integer(offset, 2) == 0x112, integer(offset + 2, 2) == 3, integer(offset + 4, 4) == 1,
           let value = integer(offset + 8, 2), (1 ... 8).contains(value)
        { return value }
      }
      return nil
    }
  }
#endif
