import StructuredQueries
import StructuredQueriesSQLite

@Table("revisions")
struct RevisionRow {
  @Column("rev", primaryKey: true) var rev: Int64
  @Column("mtime") var mtime: String
  @Column("grp") var grp: String
}

@Table("blobs")
struct BlobRow {
  @Column("hash", primaryKey: true) var hash: String
  @Column("content") var content: [UInt8]
}

@Table("fs_versions")
struct FSVersionRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("rev") var rev: Int64
  @Column("kind") var kind: String?
  @Column("blob_hash") var blobHash: String?
  @Column("op") var op: String
  @Column("aux") var aux: String?
}

@Table("fs_heads")
struct FSHeadRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("parent_path") var parentPath: String
  @Column("kind") var kind: String
  @Column("blob_hash") var blobHash: String?
  @Column("size") var size: Int64
  @Column("line_count") var lineCount: Int64?
  @Column("etag") var etag: String
  @Column("rev") var rev: Int64
  @Column("mtime") var mtime: String
}

@Table("docs")
struct DocRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("title") var title: String
  @Column("kind") var kind: String?
  @Column("status") var status: String?
}

@Table("links")
struct LinkRow {
  @Column("grp") var grp: String
  @Column("src") var src: String
  @Column("dst_grp") var dstGroup: String
  @Column("dst") var dst: String
}

@Table("doc_custom_attrs")
struct DocCustomAttrRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("name") var name: String
  @Column("ord") var ord: Int64
  @Column("value") var value: String
}

@Table("tables")
struct TableNodeRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("created_rev") var createdRev: Int64
}

@Table("table_schema_versions")
struct TableSchemaVersionRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("rev") var rev: Int64
  @Column("header_json") var headerJSON: String
}

@Table("table_rows")
struct TableRowRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("row_id") var rowID: Int64
  @Column("created_rev") var createdRev: Int64
  @Column("deleted_rev") var deletedRev: Int64?
  @Column("payload") var payload: String
}

@Table("machines")
struct MachineRow {
  @Column("id", primaryKey: true) var id: String
  @Column("account_id") var accountID: String
  @Column("name") var name: String?
  @Column("created_at") var createdAt: String
  @Column("grp") var grp: String
  @Column("scope") var scope: String
}

@Table("script_execs")
struct ScriptExecRow {
  @Column("exec_id", primaryKey: true) var execID: String
  @Column("script_id") var scriptID: String
  @Column("session_id") var sessionID: String
  @Column("grp") var grp: String
}
