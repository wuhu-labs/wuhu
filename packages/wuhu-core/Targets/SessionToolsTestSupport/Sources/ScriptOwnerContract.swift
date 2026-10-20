#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import protocol MainHub.Main
import enum MainHub.ScriptDataOperation
import SessionDomain
import SpaceCore
import SpaceTools
import WuhuAI

public struct ScriptOwnerContract {
  let owner: any Main
  let session: SessionID
  public init(owner: any Main, session: SessionID) { self.owner = owner; self.session = session }

  public func guardedFilesAndFrozenModules() async throws {
    let first = try await owner.writeBytes("/owner.js", data: Data("export default 1".utf8), ifMatch: nil, session: session)
    let snapshot = try await owner.moduleSnapshot(for: session)
    let second = try await owner.writeBytes("/owner.js", data: Data("export default 2".utf8), ifMatch: first.token, session: session)
    try require(second.token != first.token)
    try require(try await owner.moduleBytes(path: "/owner.js", shown: "/owner.js", group: snapshot.acting, snapshot: snapshot) == Data("export default 1".utf8))
    try require(try await owner.readBytes("/owner.js", rev: nil, byteLimit: 1024, session: session).data == Data("export default 2".utf8))
    do {
      _ = try await owner.writeBytes("/owner.js", data: Data(), ifMatch: first.token, session: session)
      throw ScriptOwnerContractFailure.violation("a stale token replaced a file")
    } catch let error as ToolRunError {
      guard case let .failed(code, _, _, token) = error else { throw error }
      try require(code == .conflict)
      try require(token == second.token)
    }
    do {
      _ = try await owner.writeBytes("/_/sessions/another/file.md", data: Data(), ifMatch: nil, session: session)
      throw ScriptOwnerContractFailure.violation("owner allowed a foreign session home write")
    } catch let error as ToolRunError {
      guard case let .failed(code, _, _, _) = error else { throw error }
      try require(code == .unauthorized)
    }
    let restored = try await owner.checkout("/owner.js", rev: try required(first.rev), ifMatch: second.token, session: session)
    try require(restored.object?["token"] != nil)
    try require(try await owner.readBytes("/owner.js", rev: nil, byteLimit: 1024, session: session).data == Data("export default 1".utf8))
  }

  public func typedDataAndQueryStream() async throws {
    _ = try await owner.dataOperation(.createTable, input: ["path": "/owner.table", "header": ["columns": [["name": "n", "type": "integer"]]]], session: session)
    let sql = "SELECT n FROM \"/owner.table\""
    var iterator = try await owner.observe(sql, parameters: [], session: session).makeAsyncIterator()
    try require(try await iterator.next()?.rows.isEmpty == true)
    let commit = try await owner.commitRows("/owner.table", edits: [.insert(["n": 7])], session: session)
    try require(commit.object?["ids"]?.array?.count == 1)
    try require(try await iterator.next()?.rows == [[.integer(7)]])
    try require(try await owner.query(sql + " WHERE n = ?", parameters: [7], byteLimit: 1024, session: session).rows == [[.integer(7)]])
    do {
      _ = try await owner.query("SELECT 'oversize'", parameters: [], byteLimit: 1, session: session)
      throw ScriptOwnerContractFailure.violation("query crossed its buffer budget")
    } catch SpaceError.queryResultTooLarge {}
    do {
      _ = try await owner.observe("SELECT * FROM unknown_owner_relation", parameters: [], session: session)
      throw ScriptOwnerContractFailure.violation("invalid observe query was admitted")
    } catch {}
  }
}

public enum ScriptOwnerContractFailure: Error, Sendable { case violation(String) }
private func require(_ value: Bool) throws { guard value else { throw ScriptOwnerContractFailure.violation("Owner contract condition failed") } }
private func required<Value>(_ value: Value?) throws -> Value { guard let value else { throw ScriptOwnerContractFailure.violation("Owner contract value was absent") }; return value }
