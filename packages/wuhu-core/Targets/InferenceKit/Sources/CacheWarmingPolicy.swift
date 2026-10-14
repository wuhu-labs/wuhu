#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct CacheWarmingPolicy: Hashable, Sendable, Codable {
  public var intervalSeconds: Int
  public var maxPings: Int
  public var minimumRemainingPercent: Double
  public var compactionThresholdTokens: Int
  public var compactionGrowthTokens: Int

  public init(intervalSeconds: Int = 3300, maxPings: Int = 20, minimumRemainingPercent: Double = 10, compactionThresholdTokens: Int = 100_000, compactionGrowthTokens: Int = 50000) {
    self.intervalSeconds = intervalSeconds
    self.maxPings = maxPings
    self.minimumRemainingPercent = minimumRemainingPercent
    self.compactionThresholdTokens = compactionThresholdTokens
    self.compactionGrowthTokens = compactionGrowthTokens
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case intervalSeconds, maxPings, minimumRemainingPercent, compactionThresholdTokens, compactionGrowthTokens
  }

  public init(from decoder: any Decoder) throws {
    do {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
      guard keys.allSatisfy({ CodingKeys(rawValue: $0) != nil }) else { throw CatalogError.invalidCacheWarming("unknown field") }
      func integer(_ key: CodingKeys, default value: Int) throws -> Int {
        container.contains(key) ? try container.decode(Int.self, forKey: key) : value
      }
      self.init(
        intervalSeconds: try integer(.intervalSeconds, default: 3300),
        maxPings: try integer(.maxPings, default: 20),
        minimumRemainingPercent: container.contains(.minimumRemainingPercent) ? try container.decode(Double.self, forKey: .minimumRemainingPercent) : 10,
        compactionThresholdTokens: try integer(.compactionThresholdTokens, default: 100_000),
        compactionGrowthTokens: try integer(.compactionGrowthTokens, default: 50000),
      )
      guard intervalSeconds > 0, maxPings > 0, compactionThresholdTokens > 0, compactionGrowthTokens > 0,
            minimumRemainingPercent.isFinite, (0 ... 100).contains(minimumRemainingPercent)
      else {
        throw CatalogError.invalidCacheWarming("interval, count and token thresholds must be positive; remaining percent must be 0...100")
      }
    } catch let error as CatalogError { throw error }
    catch { throw CatalogError.invalidCacheWarming(String(describing: error)) }
  }
}

private struct AnyKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
