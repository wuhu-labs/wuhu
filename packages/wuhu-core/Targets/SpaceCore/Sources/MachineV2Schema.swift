import StructuredQueries

@Table("machine_v2_operations")
struct MachineV2OperationRow {
  @Column(primaryKey: true) var id: String
  var grp: String
  @Column("owner_scope") var ownerScope: String
  @Column("invocation_key") var invocationKey: String
  @Column("machine_id") var machineID: String
  @Column("correlation_id") var correlationID: String
  @Column("input_digest") var inputDigest: String
  @Column("dispatch_consumed") var dispatchConsumed: Bool
  var record: String
  var active: Bool
  @Column("reserved_bytes") var reservedBytes: Int
  @Column("created_at") var createdAt: String
}

@Table("machine_v2_channels")
struct MachineV2ChannelRow {
  @Column(primaryKey: true) var id: String
  @Column("operation_id") var operationID: String
  var name: String
  var committed: String
  var accepted: String
  var pending: String?
}

@Table("machine_v2_output")
struct MachineV2OutputRow {
  @Column(primaryKey: true) var id: String
  @Column("operation_id") var operationID: String
  var channel: String
  var sequence: Int
  var payload: String
}

@Table("machine_v2_members")
struct MachineV2MemberRow {
  @Column("machine_id", primaryKey: true) var machineID: String
  var grp: String
  @Column("created_at") var createdAt: String
}

@Table("machine_v2_presence")
struct MachineV2PresenceRow {
  @Column("machine_id", primaryKey: true) var machineID: String
  var grp: String
  var state: String
  var description: String?
  @Column("observed_at") var observedAt: String
  var reason: String?
}

@Table("machine_v2_trace")
struct MachineV2TraceRow {
  @Column(primaryKey: true) var id: String
  var grp: String
  @Column("request_id") var requestID: String
  @Column("correlation_id") var correlationID: String
  var path: String
  var event: String
  @Column("start_at") var startAt: String
  @Column("elapsed_ms") var elapsedMs: Int
  var status: Int?
  @Column("head_ms") var headMs: Int?
  @Column("error_code") var errorCode: String?
  @Column("problem_id") var problemID: Int64?
}

@Table("machine_v2_problem_index")
struct MachineV2ProblemIndex {
  @Column(primaryKey: true) var id: String
  var grp: String
  var fingerprint: String
  @Column("row_id") var rowID: Int64
}

@Table("machine_v2_incidents")
struct MachineV2IncidentRow {
  @Column(primaryKey: true) var id: String
  var grp: String
  @Column("trace_group") var traceGroup: String
  var fingerprint: String
  @Column("correlation_id") var correlationID: String?
  @Column("problem_id") var problemID: Int64?
}

@Table("machine_v2_retention")
struct MachineV2RetentionRow {
  @Column(primaryKey: true) var id: String
  var grp: String
  var kind: String
  @Column("expired_at") var expiredAt: String
}

@Table("machine_v2_maintenance")
struct MachineV2MaintenanceRow {
  @Column(primaryKey: true) var id: String
  @Column("ran_at") var ranAt: String
}

@Table("machine_v2_key_check")
struct MachineV2KeyCheckRow {
  @Column(primaryKey: true) var id: String
  var sealed: String
}
