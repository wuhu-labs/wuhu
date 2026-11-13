#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries
import Wuwei
import WuweiQueries

extension Sessions {
  public static func streams(_ key: String, in db: Database) -> [(id: SubscriptionID, url: URL)] {
    return db.rows(StoredStream.where { $0.sessionID.eq(key) }.order { $0.armedAt }).map { row in
      (SubscriptionID(row.subscriptionID), URL(string: row.url)!)
    }
  }
}

@Table("streams")
private struct StoredStream {
  @Column("session_id") let sessionID: String?
  @Column("subscription_id") let subscriptionID: String
  let url: String
  @Column("armed_at") let armedAt: String
}
