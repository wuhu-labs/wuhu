import struct SpaceContract.GroupID
import StructuredQueries
import WuweiQueries

extension SpaceCell {
  public func observers(_ group: GroupID) throws -> [ArmedSubscription] {
    try db.rows(SubscriptionRow.of(.group(group)).order { $0.name }).map(ArmedSubscription.init(row:))
  }

  public func armedSubscriptions() throws -> [ArmedSubscription] {
    try db.rows(SubscriptionRow.order { ($0.ownerKind, $0.owner, $0.subscriptionID) }).map(ArmedSubscription.init(row:))
  }
}
