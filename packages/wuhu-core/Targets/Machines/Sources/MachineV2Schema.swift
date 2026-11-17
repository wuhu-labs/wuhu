import StructuredQueries

@Table("machine_v2_members")
struct MachineV2MemberRow {
  @Column("machine_id", primaryKey: true) var machineID: String
  var grp: String
  @Column("created_at") var createdAt: String
}
