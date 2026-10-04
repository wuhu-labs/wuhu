#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Container metadata is read before spending provider credit; no public audio URL or shell probe is needed.
enum AudioDuration {
  static func seconds(_ clip: AudioClip) -> Double? {
    let bytes = [UInt8](clip.bytes)
    switch clip.mediaType {
    case .wav: return wav(bytes)
    case .m4a, .mp4: return mp4(bytes, in: 0 ..< bytes.count)
    case .mpeg: return mp3(bytes)
    case .webm: return webm(bytes)
    }
  }

  static func number(_ bytes: [UInt8], _ offset: Int, _ count: Int, little: Bool = false) -> UInt64? {
    guard count <= 8, offset >= 0, offset + count <= bytes.count else { return nil }
    let slice = bytes[offset ..< offset + count]
    return (little ? Array(slice.reversed()) : Array(slice)).reduce(0) { $0 << 8 | UInt64($1) }
  }

  static func wav(_ bytes: [UInt8]) -> Double? {
    guard bytes.count >= 12, String(decoding: bytes[0 ..< 4], as: UTF8.self) == "RIFF", String(decoding: bytes[8 ..< 12], as: UTF8.self) == "WAVE" else { return nil }
    var offset = 12
    var rate: UInt64?
    var size: UInt64?
    while offset + 8 <= bytes.count {
      let tag = String(decoding: bytes[offset ..< offset + 4], as: UTF8.self)
      guard let length = number(bytes, offset + 4, 4, little: true) else { return nil }
      if tag == "fmt " { rate = number(bytes, offset + 16, 4, little: true) }
      if tag == "data" { size = length; break }
      guard length <= UInt64(bytes.count) else { return nil }
      offset += 8 + Int(length) + Int(length % 2)
    }
    guard let rate, rate > 0, let size else { return nil }
    return Double(size) / Double(rate)
  }

  static func mp4(_ bytes: [UInt8], in bounds: Range<Int>) -> Double? {
    MP4Duration.seconds(bytes, in: bounds)
  }

  static func mp3(_ bytes: [UInt8]) -> Double? {
    var offset = 0
    var seconds = 0.0
    var frames = 0
    if bytes.count >= 10, String(decoding: bytes[0 ..< 3], as: UTF8.self) == "ID3" {
      offset = 10 + bytes[6 ..< 10].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }
    while offset + 4 <= bytes.count {
      let a = bytes[offset], b = bytes[offset + 1], c = bytes[offset + 2]
      guard a == 0xFF, b & 0xE0 == 0xE0, b & 6 == 2 else { offset += 1; continue }
      let version = (b >> 3) & 3
      let rateIndex = Int((c >> 2) & 3)
      let bitrateIndex = Int(c >> 4)
      guard version != 1, rateIndex < 3, bitrateIndex > 0, bitrateIndex < 15 else { offset += 1; continue }
      let divisor = version == 3 ? 1 : version == 2 ? 2 : 4
      let rate = [44100, 48000, 32000][rateIndex] / divisor
      let rates = version == 3 ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320] : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
      let length = (version == 3 ? 144 : 72) * rates[bitrateIndex] * 1000 / rate + Int((c >> 1) & 1)
      guard length > 0, offset + length <= bytes.count else { break }
      seconds += Double(version == 3 ? 1152 : 576) / Double(rate)
      frames += 1
      offset += length
    }
    return frames > 0 ? seconds : nil
  }

  static func webm(_ bytes: [UInt8]) -> Double? {
    func vint(_ offset: Int, id: Bool) -> (UInt64, Int)? {
      guard offset < bytes.count, bytes[offset] != 0 else { return nil }
      var mask: UInt8 = 0x80
      var length = 1
      while bytes[offset] & mask == 0 { mask >>= 1; length += 1 }
      guard length <= 8, let raw = number(bytes, offset, length) else { return nil }
      return (id ? raw : raw & ((UInt64(1) << (7 * length)) - 1), length)
    }
    var scale = 1_000_000.0
    var duration: Double?
    var cluster = 0.0
    var last = 0.0
    var sawBlock = false
    var offset = 0
    while offset < bytes.count {
      guard let (id, idLength) = vint(offset, id: true), let (length, lengthBytes) = vint(offset + idLength, id: false) else { break }
      let start = offset + idLength + lengthBytes
      if [0x1A45_DFA3, 0x1853_8067, 0x1549_A966, 0x1F43_B675, 0xA0].contains(id) { offset = start; continue }
      guard length <= UInt64(bytes.count - start) else { break }
      let count = Int(length)
      if id == 0x2AD7B1, let value = number(bytes, start, count) { scale = Double(value) }
      if id == 0x4489 {
        if count == 4, let raw = number(bytes, start, 4) { duration = Double(Float(bitPattern: UInt32(raw))) }
        if count == 8, let raw = number(bytes, start, 8) { duration = Double(bitPattern: raw) }
      }
      if id == 0xE7, let value = number(bytes, start, count) { cluster = Double(value) }
      if id == 0xA3 || id == 0xA1, let (_, trackBytes) = vint(start, id: false), trackBytes + 2 <= count, let raw = number(bytes, start + trackBytes, 2) {
        last = max(last, cluster + Double(Int16(bitPattern: UInt16(raw))))
        sawBlock = true
      }
      offset = start + count
    }
    if let duration, duration.isFinite, duration >= 0 { return duration * scale / 1e9 }
    return sawBlock ? (last * scale / 1e9 + 0.12) : nil
  }
}
