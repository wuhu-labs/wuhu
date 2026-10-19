#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import SpaceCore
import SpaceTools

public func rowsMarker(_ rows: Rows) -> String {
  let canonical = Wire.queryOutput(rows).jsonString()
  return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
}
