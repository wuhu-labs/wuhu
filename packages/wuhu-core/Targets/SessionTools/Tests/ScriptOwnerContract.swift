#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
import enum SessionTools.ScriptDataOperation
import protocol SessionTools.ScriptOwnerClient
import protocol SessionTools.ToolOwnerClient
import SpaceCore
import SpaceTools
import Testing
import WuhuAI

struct ScriptOwnerContract {
  let owner: any ToolOwnerClient
  let session: SessionID

  func guardedFilesAndFrozenModules() async throws {
    let first = try await owner.writeBytes("/owner.js", data: Data("export default 1".utf8), ifMatch: nil, session: session)
    let snapshot = try await owner.moduleSnapshot(for: session)
    let second = try await owner.writeBytes("/owner.js", data: Data("export default 2".utf8), ifMatch: first.token, session: session)
    #expect(second.token != first.token)
    #expect(try await owner.moduleBytes(path: "/owner.js", shown: "/owner.js", group: snapshot.acting, snapshot: snapshot) == Data("export default 1".utf8))
    #expect(try await owner.readBytes("/owner.js", rev: nil, byteLimit: 1024, session: session).data == Data("export default 2".utf8))
    do {
      _ = try await owner.writeBytes("/owner.js", data: Data(), ifMatch: first.token, session: session)
      Issue.record("a stale token replaced a file")
    } catch let error as ToolRunError {
      guard case let .failed(code, _, _, token) = error else { throw error }
      #expect(code == .conflict)
      #expect(token == second.token)
    }
    do {
      _ = try await owner.writeBytes("/_/sessions/another/file.md", data: Data(), ifMatch: nil, session: session)
      Issue.record("owner allowed a foreign session home write")
    } catch let error as ToolRunError {
      guard case let .failed(code, _, _, _) = error else { throw error }
      #expect(code == .unauthorized)
    }
    let restored = try await owner.checkout("/owner.js", rev: try #require(first.rev), ifMatch: second.token, session: session)
    #expect(restored.object?["token"] != nil)
    #expect(try await owner.readBytes("/owner.js", rev: nil, byteLimit: 1024, session: session).data == Data("export default 1".utf8))
  }

  func typedDataAndQueryStream() async throws {
    _ = try await owner.dataOperation(.createTable, input: ["path": "/owner.table", "header": ["columns": [["name": "n", "type": "integer"]]]], session: session)
    let sql = "SELECT n FROM \"/owner.table\""
    var iterator = try await owner.observe(sql, parameters: [], session: session).makeAsyncIterator()
    #expect(try await iterator.next()?.rows.isEmpty == true)
    let commit = try await owner.commitRows("/owner.table", edits: [.insert(["n": 7])], session: session)
    #expect(commit.object?["ids"]?.array?.count == 1)
    #expect(try await iterator.next()?.rows == [[.integer(7)]])
    #expect(try await owner.query(sql + " WHERE n = ?", parameters: [7], byteLimit: 1024, session: session).rows == [[.integer(7)]])
    do {
      _ = try await owner.query("SELECT 'oversize'", parameters: [], byteLimit: 1, session: session)
      Issue.record("query crossed its buffer budget")
    } catch SpaceError.queryResultTooLarge {}
    do {
      _ = try await owner.observe("SELECT * FROM unknown_owner_relation", parameters: [], session: session)
      Issue.record("invalid observe query was admitted")
    } catch {}
  }

  func persistentToolReceipts() async throws {
    let call = ToolCall(id: "owner-receipt", name: "write", arguments: .object(["path": "/receipt.md", "content": "first"]))
    let first = try await owner.execute(session: session, call: call, state: .init())
    let replay = try await owner.execute(session: session, call: call, state: .init())
    #expect(first == replay)
    #expect(try await owner.readBytes("/receipt.md", rev: nil, byteLimit: 1024, session: session).data == Data("first".utf8))
  }
}
