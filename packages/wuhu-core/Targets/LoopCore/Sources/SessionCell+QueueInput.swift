#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceCore.SessionPut
import StructuredQueries
import Wuwei
import WuweiQueries

extension SessionCell {
  mutating func put(_ id: SessionID, _ put: SessionPut) throws {
    try insertInput(id.rawValue, put, nowDate: now())
  }

  mutating func clear(_ id: SessionID, topic: String) throws {
    try removeInput(id.rawValue, topic: topic)
  }
}
