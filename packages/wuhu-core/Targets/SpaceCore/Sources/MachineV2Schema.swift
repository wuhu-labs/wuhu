import StructuredQueries

let machineV2SchemaSQL = """
CREATE TABLE IF NOT EXISTS machine_v2_retention (id TEXT PRIMARY KEY, grp TEXT NOT NULL, kind TEXT NOT NULL, expired_at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS machine_v2_retention_expiry ON machine_v2_retention(grp, kind, expired_at);
CREATE TABLE IF NOT EXISTS machine_v2_maintenance (id TEXT PRIMARY KEY, ran_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS machine_v2_members (machine_id TEXT PRIMARY KEY REFERENCES machines(id), grp TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS machine_v2_presence (machine_id TEXT PRIMARY KEY, grp TEXT NOT NULL, state TEXT NOT NULL, description TEXT, observed_at TEXT NOT NULL, reason TEXT);
CREATE TABLE IF NOT EXISTS machine_v2_operations (id TEXT PRIMARY KEY, grp TEXT NOT NULL, owner_scope TEXT NOT NULL, invocation_key TEXT NOT NULL, machine_id TEXT NOT NULL, correlation_id TEXT NOT NULL, input_digest TEXT NOT NULL, dispatch_consumed INTEGER NOT NULL, record TEXT NOT NULL, active INTEGER NOT NULL, reserved_bytes INTEGER NOT NULL, created_at TEXT NOT NULL, UNIQUE(grp, owner_scope, invocation_key));
CREATE TABLE IF NOT EXISTS machine_v2_channels (id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES machine_v2_operations(id) ON DELETE CASCADE, name TEXT NOT NULL, committed TEXT NOT NULL, accepted TEXT NOT NULL, pending TEXT);
CREATE TABLE IF NOT EXISTS machine_v2_output (id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES machine_v2_operations(id) ON DELETE CASCADE, channel TEXT NOT NULL, sequence INTEGER NOT NULL, payload TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS machine_v2_trace (id TEXT PRIMARY KEY, grp TEXT NOT NULL, request_id TEXT NOT NULL, correlation_id TEXT NOT NULL, path TEXT NOT NULL, event TEXT NOT NULL, start_at TEXT NOT NULL, elapsed_ms INTEGER NOT NULL, status INTEGER, head_ms INTEGER, error_code TEXT, problem_id INTEGER);
CREATE INDEX IF NOT EXISTS machine_v2_trace_correlation ON machine_v2_trace(grp, correlation_id, start_at);
CREATE TABLE IF NOT EXISTS machine_v2_problem_index (id TEXT PRIMARY KEY, grp TEXT NOT NULL, fingerprint TEXT NOT NULL, row_id INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS machine_v2_incidents (id TEXT PRIMARY KEY, grp TEXT NOT NULL, trace_group TEXT NOT NULL, fingerprint TEXT NOT NULL, correlation_id TEXT, problem_id INTEGER);
"""

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
