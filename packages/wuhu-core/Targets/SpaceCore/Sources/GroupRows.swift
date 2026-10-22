import StructuredQueries
import StructuredQueriesSQLite

@Table("groups")
struct GroupRow {
  @Column(primaryKey: true) var id: String
  @Column("created_at") var createdAt: String
  @Column("personal_account") var personalAccount: String?
  @Column("removed_at") var removedAt: String?
  var visibility: String
  @Column("secrets_scope") var secretsScope: String
}

@Table("group_roles")
struct GroupRoleRow {
  @Column("account_id") var accountID: String?
  @Column("source_group") var sourceGroup: String?
  var grp: String
  var role: String
  @Column("created_at") var createdAt: String
}

@Table("accounts")
struct GroupAccountRow {
  @Column(primaryKey: true) var id: String
  var kind: String
  var guest: Bool
  @Column("removed_at") var removedAt: String?
}

@Table("sessions")
struct GroupSessionRow {
  @Column(primaryKey: true) var id: String
  var grp: String
  var kind: String
  var parent: String?
  var lifecycle: String

  var isLiveRoot: Bool { kind == "agent" && parent == nil && lifecycle == "live" }
  var isLive: Bool { lifecycle == "live" }
}
