#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

enum MP4Duration {
  private enum Invalid: Error { case timing }
  private struct Box {
    var name: String
    var payload: Range<Int>
  }

  private struct Track {
    var scale: UInt64
    var duration: Double?
  }

  private struct Reader {
    var bytes: [UInt8]

    func number(_ box: Box, _ offset: Int, _ count: Int = 4) throws -> UInt64 {
      guard offset >= 0, offset + count <= box.payload.count,
            let value = AudioDuration.number(bytes, box.payload.lowerBound + offset, count)
      else { throw Invalid.timing }
      return value
    }

    func boxes(in range: Range<Int>) throws -> [Box] {
      var result: [Box] = []
      var offset = range.lowerBound
      while offset + 8 <= range.upperBound {
        guard var size = AudioDuration.number(bytes, offset, 4) else { throw Invalid.timing }
        var header = 8
        if size == 1 {
          guard offset + 16 <= range.upperBound, let extended = AudioDuration.number(bytes, offset + 8, 8) else { throw Invalid.timing }
          size = extended
          header = 16
        }
        if size == 0 { size = UInt64(range.upperBound - offset) }
        guard size >= UInt64(header), size <= UInt64(range.upperBound - offset) else { throw Invalid.timing }
        let end = offset + Int(size)
        result.append(Box(name: String(decoding: bytes[offset + 4 ..< offset + 8], as: UTF8.self), payload: offset + header ..< end))
        offset = end
      }
      guard offset == range.upperBound else { throw Invalid.timing }
      return result
    }

    func one(_ name: String, in boxes: [Box]) throws -> Box {
      let matching = boxes.filter { $0.name == name }
      guard matching.count == 1 else { throw Invalid.timing }
      return matching[0]
    }

    func timing(_ box: Box) throws -> Track {
      let version = try number(box, 0, 1)
      guard version <= 1 else { throw Invalid.timing }
      let offset = version == 1 ? 20 : 12
      let scale = try number(box, offset)
      let ticks = try number(box, offset + 4, version == 1 ? 8 : 4)
      guard scale > 0 else { throw Invalid.timing }
      let unknown = version == 1 ? UInt64.max : UInt64(UInt32.max)
      return Track(scale: scale, duration: ticks == unknown ? nil : Double(ticks) / Double(scale))
    }

    func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
      let (value, overflow) = a.addingReportingOverflow(b)
      guard !overflow else { throw Invalid.timing }
      return value
    }

    func run(_ box: Box, defaultDuration: UInt64?, start: UInt64) throws -> (end: UInt64, presentationEnd: UInt64, samples: UInt64) {
      let version = try number(box, 0, 1)
      let flags = try number(box, 1, 3)
      guard version <= 1, flags & ~UInt64(0xF05) == 0 else { throw Invalid.timing }
      let count = try number(box, 4)
      var offset = 8
      if flags & 1 != 0 { _ = try number(box, offset); offset += 4 }
      if flags & 4 != 0 { _ = try number(box, offset); offset += 4 }
      let fields = [UInt64(0x100), 0x200, 0x400, 0x800].filter { flags & $0 != 0 }
      let stride = fields.count * 4
      guard offset <= box.payload.count, count * UInt64(stride) == UInt64(box.payload.count - offset) else { throw Invalid.timing }
      if stride == 0 {
        guard count == 0 || (defaultDuration ?? 0) > 0 else { throw Invalid.timing }
        let (ticks, overflow) = count.multipliedReportingOverflow(by: defaultDuration ?? 0)
        guard !overflow else { throw Invalid.timing }
        let end = try add(start, ticks)
        return (end, end, count)
      }
      var end = start
      var presentationEnd = start
      for _ in 0 ..< count {
        var duration = defaultDuration
        var composition: UInt64 = 0
        for field in fields {
          let value = try number(box, offset)
          offset += 4
          if field == 0x100 { duration = value }
          if field == 0x800 {
            composition = version == 0 ? value : UInt64(max(0, Int64(Int32(bitPattern: UInt32(value)))))
          }
        }
        guard let duration, duration > 0 else { throw Invalid.timing }
        end = try add(end, duration)
        presentationEnd = max(presentationEnd, try add(end, composition))
      }
      return (end, presentationEnd, count)
    }

    func seconds(in bounds: Range<Int>) throws -> Double {
      let root = try boxes(in: bounds)
      let movie = try boxes(in: one("moov", in: root).payload)
      var duration: Double?
      for header in movie where header.name == "mvhd" { duration = try timing(header).duration }
      var tracks: [UInt64: Track] = [:]
      for box in movie where box.name == "trak" {
        let children = try boxes(in: box.payload)
        let header = try one("tkhd", in: children)
        let version = try number(header, 0, 1)
        guard version <= 1 else { throw Invalid.timing }
        let id = try number(header, version == 1 ? 20 : 12)
        guard id > 0, tracks[id] == nil else { throw Invalid.timing }
        let media = try boxes(in: one("mdia", in: children).payload)
        let track = try timing(one("mdhd", in: media))
        tracks[id] = track
        if let value = track.duration { duration = max(duration ?? 0, value) }
      }
      var defaults: [UInt64: UInt64] = [:]
      for box in movie where box.name == "mvex" {
        for item in try boxes(in: box.payload) where item.name == "trex" {
          guard try number(item, 0) == 0, item.payload.count == 24 else { throw Invalid.timing }
          let id = try number(item, 4)
          guard tracks[id] != nil, defaults[id] == nil else { throw Invalid.timing }
          defaults[id] = try number(item, 12)
        }
      }
      let fragments = root.filter { $0.name == "moof" }
      if fragments.isEmpty {
        guard !movie.contains(where: { $0.name == "mvex" }), let duration else { throw Invalid.timing }
        return duration
      }
      var totals: [UInt64: UInt64] = [:]
      for fragment in fragments {
        let groups = try boxes(in: fragment.payload).filter { $0.name == "traf" }
        guard !groups.isEmpty else { throw Invalid.timing }
        for group in groups {
          let children = try boxes(in: group.payload)
          let header = try one("tfhd", in: children)
          let flags = try number(header, 1, 3)
          guard try number(header, 0, 1) == 0, flags & ~UInt64(0x03003B) == 0, flags & 0x010000 == 0 else { throw Invalid.timing }
          let id = try number(header, 4)
          guard let track = tracks[id] else { throw Invalid.timing }
          var offset = 8
          if flags & 1 != 0 { _ = try number(header, offset, 8); offset += 8 }
          if flags & 2 != 0 { _ = try number(header, offset); offset += 4 }
          var defaultDuration = defaults[id]
          if flags & 8 != 0 { defaultDuration = try number(header, offset); offset += 4 }
          if flags & 0x10 != 0 { _ = try number(header, offset); offset += 4 }
          if flags & 0x20 != 0 { _ = try number(header, offset); offset += 4 }
          guard offset == header.payload.count else { throw Invalid.timing }
          let decode = try one("tfdt", in: children)
          let version = try number(decode, 0, 1)
          guard version <= 1, try number(decode, 1, 3) == 0, decode.payload.count == (version == 1 ? 12 : 8) else { throw Invalid.timing }
          let start = try number(decode, 4, version == 1 ? 8 : 4)
          var end = start
          var samples: UInt64 = 0
          for box in children where box.name == "trun" {
            let timing = try run(box, defaultDuration: defaultDuration, start: end)
            end = timing.end
            samples = try add(samples, timing.samples)
            duration = max(duration ?? 0, Double(timing.presentationEnd) / Double(track.scale))
          }
          guard samples > 0 else { throw Invalid.timing }
          let total = try add(totals[id] ?? 0, end - start)
          totals[id] = total
          duration = max(duration ?? 0, Double(total) / Double(track.scale))
        }
      }
      guard let duration else { throw Invalid.timing }
      return duration
    }
  }

  static func seconds(_ bytes: [UInt8], in bounds: Range<Int>) -> Double? {
    try? Reader(bytes: bytes).seconds(in: bounds)
  }
}
