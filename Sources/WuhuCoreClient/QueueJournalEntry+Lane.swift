import Foundation

public extension UserQueueJournalEntry {
  var lane: UserQueueLane {
    switch self {
    case let .enqueued(lane, item: _):
      lane
    case let .canceled(lane, id: _, at: _):
      lane
    case let .materialized(lane, id: _, transcriptEntryID: _, at: _):
      lane
    }
  }
}
