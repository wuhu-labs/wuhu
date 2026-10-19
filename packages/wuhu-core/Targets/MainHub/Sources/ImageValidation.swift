#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public func neverOverwrites(_ path: String) -> ToolProblem {
  ToolProblem("\(path) already exists; generate_image never overwrites")
}

public struct PNGHeader: Equatable {
  public let width: Int
  public let height: Int

  public init?(_ data: Data) {
    let bytes = [UInt8](data.prefix(24))
    guard bytes.count == 24,
          bytes[0 ..< 8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
          bytes[12 ..< 16].elementsEqual(Array("IHDR".utf8))
    else { return nil }
    func word(_ at: Int) -> Int { bytes[at ..< at + 4].reduce(0) { $0 << 8 | Int($1) } }
    width = word(16)
    height = word(20)
  }
}
