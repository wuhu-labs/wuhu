import SessionDomain
import struct SpaceCore.ArmedSubscription
import struct SpaceCore.SubscriptionRow
import struct SpaceIDs.SessionID
import struct SpaceIDs.SubscriptionID

extension SessionCell {
  func observation(_ id: SessionID, _ subscription: SubscriptionID) throws -> ArmedSubscription? {
    try SubscriptionRow.find(id.rawValue, subscription.rawValue, in: db).map(ArmedSubscription.init(row:))
  }
}
