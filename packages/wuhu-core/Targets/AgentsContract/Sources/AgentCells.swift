import struct SpaceIDs.SessionID
import Wuwei

public protocol SessionReading {
  var summary: SessionSummary? { get }
}

public struct AgentCells: Sendable {
  public var session: @Sendable (any CellReading, SessionID) -> any SessionReading

  public init(session: @escaping @Sendable (any CellReading, SessionID) -> any SessionReading) {
    self.session = session
  }
}

extension CellContext {
  public func session(_ id: SessionID) -> any SessionReading {
    dependency(AgentCells.self).session(self, id)
  }
}
