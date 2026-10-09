import Fetch
import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceContract
import SpaceCore
import SpaceFS
import SpaceTools
import Testing

@Suite struct ScriptFileTests {
  @Test func bytesTextTokensAndPagedHistory() async throws {
    try await withRig { rig in
      let value = try await rig.evaluate(#"""
      import {readBytes,readText,writeBytes,writeText,stat,list,history,checkout,move,remove} from 'wuhu:space'
      const codes=[]
      const attempt=async f=>{try {await f(); codes.push('ok')} catch(e) {codes.push(e.code)}}
      await attempt(()=>writeText('/file.md','missing guard'))
      const first=await writeBytes('/file.md',new Uint8Array([0,255,65]),{ifMatch:null})
      await attempt(()=>readText('/file.md'))
      const bytes=await readBytes('/file.md')
      const races=await Promise.allSettled([1,2].map(n=>writeText('/race.md',String(n),{ifMatch:null})))
      await attempt(()=>writeText('/file.md','exists',{ifMatch:null}))
      const second=await writeText('/file.md','second',{ifMatch:first.token})
      await attempt(()=>writeText('/file.md','stale',{ifMatch:first.token}))
      const old=await readBytes('/file.md',{rev:first.rev})
      await attempt(()=>checkout('/file.md',first.rev))
      await attempt(()=>checkout('/file.md',first.rev,{ifMatch:first.token}))
      await checkout('/file.md',first.rev,{ifMatch:second.token})
      const page=await history('/file.md',{limit:1})
      const page2=await history('/file.md',{after:page.next,limit:1})
      const current=await stat('/file.md')
      await move('/file.md','/moved.md')
      const moved=await stat('/moved.md')
      await remove('/moved.md',{ifMatch:moved.token})
      const journal=await history('/moved.md')
      const system=await readText('wuhu://system/AGENTS.md')
      await attempt(()=>writeText('wuhu://system/AGENTS.md','bad',{ifMatch:null}))
      await attempt(()=>writeText('/invalid.table','bad',{ifMatch:null}))
      await attempt(()=>readText('/race.md',{force:true}))
      await attempt(()=>readText('machines://box/file.md'))
      result({codes,bytes:Array.from(bytes.data),old:Array.from(old.data),races:races.filter(r=>r.status==='fulfilled').length,page:page.entries.length,page2:page2.entries.length,ordered:page2.entries[0].rev>page.entries[0].rev,changes:journal.entries.map(x=>x.change),system:system.content.length>0,list:(await list('/')).entries.length>0,token:current.token!==first.token})
      """#)
      #expect(value.object?["codes"] == ["invalidArgument", "unsupported", "conflict", "conflict", "invalidArgument", "conflict", "unsupported", "invalidArgument", "invalidArgument", "invalidPath"])
      #expect(value.object?["bytes"] == [0, 255, 65])
      #expect(value.object?["old"] == [0, 255, 65])
      #expect(value.object?["races"] == 1)
      #expect(value.object?["page"] == 1)
      #expect(value.object?["page2"] == 1)
      #expect(value.object?["ordered"] == true)
      #expect(value.object?["changes"] == ["write", "delete"])
      #expect(value.object?["system"] == true)
      #expect(value.object?["list"] == true)
      #expect(value.object?["token"] == true)
    }
  }

  @Test(arguments: ["root", "child", "task"]) func checkedWriteMoveCheckoutAndRemove(kind: String) async throws {
    for home in [GroupID.shared, GroupID(rawValue: "alice")] {
      try await withRig(group: home, task: kind == "task", childAgent: kind == "child") { rig in
        let principal = try await rig.space.principal(of: rig.session)
        let context = SpaceToolContext(space: rig.space, principal: principal)
        let paths: [(String, String)] = [
          ("/ordinary.md", "ok"),
          ("/.agents/skills/example/file.md", home == .shared && kind != "root" ? "unauthorized" : "ok"),
          ("wuhu://shared.localspace/shared.md", "ok"),
          ("wuhu://shared.localspace/.agents/skills/example/shared.md", home == .shared && kind == "root" ? "ok" : "unauthorized"),
          ("/_/sessions/\(rig.session.rawValue)/file.md", "ok"),
          ("/_/sessions/stranger/file.md", "unauthorized"),
          ("wuhu://missing.localspace/file.md", "notFound"),
        ]
        for (address, expected) in paths {
          let group: GroupID = address.hasPrefix("wuhu://shared") ? .shared : home
          let path = address.hasPrefix("wuhu://shared.localspace") ? String(address.dropFirst("wuhu://shared.localspace".count)) : address
          var token = "1"
          if expected != "notFound" {
            token = String(decoding: try await rig.space.fs(group).write(path, Data("before".utf8), ifMatch: nil).bytes, as: UTF8.self)
          }
          let raw = JSONValue.string(address).jsonString()
          let guardToken = JSONValue.string(token).jsonString()
          let operations: [(String, JSONValue, String)] = [
            ("write", ["path": .string(address), "content": "after", "ifMatch": .string(token)], "writeText(\(raw),'after',{ifMatch:\(guardToken)})"),
            ("checkout", ["path": .string(address), "rev": .integer(Int(token) ?? 1), "ifMatch": .string(token)], "checkout(\(raw),\(token),{ifMatch:\(guardToken)})"),
            ("mv", ["from": .string(address), "to": .string(address + ".moved")], "move(\(raw),\(JSONValue.string(address + ".moved").jsonString()))"),
            ("rm", ["path": .string(address), "ifMatch": .string(token)], "remove(\(raw),{ifMatch:\(guardToken)})"),
          ]
          for (verb, input, call) in operations {
            if expected == "ok" { continue }
            do { _ = try await SpaceToolbox.all.first { $0.name == verb }!.run(context, input: input); Issue.record("HTTP \(verb) unexpectedly allowed \(address)") }
            catch { #expect(Wire.failure(error).payload.object?["code"] == .string(expected)) }
            #expect(try await rig.evaluate("import {writeText,checkout,move,remove} from 'wuhu:space'; try {await \(call); result('ok')} catch(e) {result(e.code)}") == .string(expected))
          }
          if expected == "ok" {
            let sibling = address + ".http"
            let plainSibling = path + ".http"
            let initial = String(decoding: try await rig.space.fs(group).write(plainSibling, Data("before".utf8), ifMatch: nil).bytes, as: UTF8.self)
            let changed = try await SpaceToolbox.all.first { $0.name == "write" }!.run(context, input: ["path": .string(sibling), "content": "after", "ifMatch": .string(initial)])
            _ = try await SpaceToolbox.all.first { $0.name == "checkout" }!.run(context, input: ["path": .string(sibling), "rev": .integer(Int(initial)!), "ifMatch": changed.object?["token"] ?? .null])
            _ = try await SpaceToolbox.all.first { $0.name == "mv" }!.run(context, input: ["from": .string(sibling), "to": .string(sibling + ".moved")])
            let current = try await SpaceToolbox.all.first { $0.name == "stat" }!.run(context, input: ["path": .string(sibling + ".moved")])
            _ = try await SpaceToolbox.all.first { $0.name == "rm" }!.run(context, input: ["path": .string(sibling + ".moved"), "ifMatch": current.object?["token"] ?? .null])
            #expect(try await rig.evaluate("import {writeText,checkout,stat,move,remove} from 'wuhu:space'; const w=await writeText(\(raw),'after',{ifMatch:\(guardToken)}); await checkout(\(raw),\(token),{ifMatch:w.token}); await move(\(raw),\(JSONValue.string(address + ".moved").jsonString())); const m=await stat(\(JSONValue.string(address + ".moved").jsonString())); await remove(\(JSONValue.string(address + ".moved").jsonString()),{ifMatch:m.token});result('ok')") == "ok")
          }
        }
      }
    }
  }

  @Test func nullCheckoutRestoresDeletedFilesAndTablesAtomically() async throws {
    try await withRig { rig in
      let value = try await rig.evaluate(#"""
      import {createTable,mutateRows,query,writeText,readText,stat,checkout,remove} from 'wuhu:space'
      const first=await writeText('/restore.md','original',{ifMatch:null})
      const created=await createTable('/restore.table',{columns:[{name:'name',type:'string'}]})
      const rows=await mutateRows('/restore.table',[{insert:{name:'kept'}}])
      await remove('/restore.md')
      await remove('/restore.table')
      const codes=[]
      for(const options of [undefined,{}, {ifMatch:''},{ifMatch:1}]) {
        try {await checkout('/restore.table',rows.rev,options);codes.push('ok')} catch(e) {codes.push(e.code)}
      }
      const table=await checkout('/restore.table',rows.rev,{ifMatch:null})
      const races=await Promise.allSettled([1,2].map(()=>checkout('/restore.md',first.rev,{ifMatch:null})))
      let exists
      try {await writeText('/restore.md','do not replace',{ifMatch:null})} catch(e) {exists={code:e.code,message:e.message,hint:e.hint}}
      let checkoutExists
      try {await checkout('/restore.table',rows.rev,{ifMatch:null})} catch(e) {checkoutExists={code:e.code,message:e.message}}
      let stale
      try {await checkout('/restore.table',created.rev,{ifMatch:created.token})} catch(e) {stale={code:e.code,token:e.token}}
      result({codes,rows:await query('SELECT name FROM "/restore.table"'),content:(await readText('/restore.md')).content,races:races.filter(r=>r.status==='fulfilled').length,exists,checkoutExists,stale,token:table.token})
      """#)
      #expect(value.object?["codes"] == ["invalidArgument", "invalidArgument", "invalidArgument", "invalidArgument"])
      #expect(value.object?["rows"] == [["name": "kept"]])
      #expect(value.object?["content"] == "original")
      #expect(value.object?["races"] == 1)
      #expect(value.object?["exists"]?.object?["code"] == "conflict")
      #expect(value.object?["exists"]?.object?["message"] == "already exists: /restore.md")
      #expect(value.object?["exists"]?.object?["hint"] == "Choose another path; create-only operations never replace an existing entry.")
      #expect(value.object?["checkoutExists"] == ["code": "conflict", "message": "already exists: /restore.table"])
      #expect(value.object?["stale"]?.object?["code"] == "conflict")
      #expect(value.object?["stale"]?.object?["token"] == value.object?["token"])
    }
  }

  @Test func listingBoundsApplyToLiveHistoricalAndHiddenRootViews() async throws {
    try await withRig { rig in
      var rev = 0
      for index in 0 ..< 501 {
        let token = try await rig.space.fs(.shared).write("/many/\(index).md", Data(), ifMatch: nil)
        rev = Int(String(decoding: token.bytes, as: UTF8.self))!
      }
      #expect(try await rig.space.fs(.shared, listingLimit: 7).list("/many").1.count == 7)
      #expect(try await rig.space.fs(.shared, at: Rev(rev), listingLimit: 7).list("/many").1.count == 7)
      #expect(try await rig.evaluate("import {list} from 'wuhu:space';const codes=[];for(const options of [{},{rev:\(rev)}]){try{await list('/many',options);codes.push('ok')}catch(e){codes.push(e.code)}};result(codes)") == ["invalidArgument", "invalidArgument"])
      _ = try await rig.space.fs(.shared).delete("/many/500.md", ifMatch: nil)
      #expect(try await rig.evaluate("import {list} from 'wuhu:space';result((await list('/many')).entries.length)") == 500)
    }
  }

  @Test func bufferedResponsesDoNotSuggestReplacingTheFile() async throws {
    let fetch = FetchClient { _ in Response(status: .ok, body: .string(String(repeating: "x", count: 20 << 20))) }
    try await withRig(fetch: fetch) { rig in
      _ = try await rig.space.fs(.shared).write("/small.md", Data("small".utf8), ifMatch: nil)
      let value = try await rig.evaluate(#"""
      import {readText,list} from 'wuhu:space'
      const responses=[]
      for(let i=0;i<3;i++) responses.push(await fetch('https://example.com/big'))
      let listingFailure
      try {await list('/')} catch(e) {listingFailure={code:e.code,message:e.message,hint:e.hint}}
      let failure
      try {await readText('/small.md')} catch(e) {failure={code:e.code,message:e.message,hint:e.hint}}
      await responses[0].text()
      result({failure,listingFailure,listed:(await list('/')).entries.length>0,content:(await readText('/small.md')).content})
      """#)
      #expect(value.object?["failure"]?.object?["code"] == "invalidArgument")
      #expect(value.object?["failure"]?.object?["hint"] == "Consume unread response bodies or machine output, or let other in-flight operations finish before retrying.")
      #expect(value.object?["listingFailure"] == value.object?["failure"])
      #expect(value.object?["listed"] == true)
      #expect(value.object?["content"] == "small")
    }
  }

  @Test func listingByteBudgetRefusesLongNamesBeforeEntryCountLimit() async throws {
    try await withRig { rig in
      let name = String(repeating: "x", count: 64 << 10)
      var rev = 0
      for index in 0 ..< 400 {
        let token = try await rig.space.fs(.shared).write("/long/\(name)\(index)", Data(), ifMatch: nil)
        rev = Int(String(decoding: token.bytes, as: UTF8.self))!
      }
      for at in [nil, Rev(rev)] {
        do {
          _ = try await rig.space.fs(.shared, at: at, listingLimit: 501, listingByteLimit: 24 << 20).list("/long")
          Issue.record("long-name listing exceeded byte allowance")
        } catch {
          #expect(error as? SpaceError == .listingResultTooLarge(byteLimit: 24 << 20))
        }
      }
      let value = try await rig.evaluate("import {list} from 'wuhu:space';const failures=[];for(const options of [{},{rev:\(rev)}]){try{await list('/long',options);failures.push('ok')}catch(e){failures.push({code:e.code,message:e.message})}};result(failures)")
      #expect(value == [["code": "invalidArgument", "message": "listing exceeds 25165824 byte allowance"], ["code": "invalidArgument", "message": "listing exceeds 25165824 byte allowance"]])
      #expect(try await rig.space.fs(.shared, listingLimit: 1, listingByteLimit: 24 << 20).list("/long").1.count == 1)
      #expect(try await rig.evaluate("import {list} from 'wuhu:space';result((await list('/')).entries.length>0)") == true)
    }
  }

  @Test func serializedSizePreflightMatchesTheJSONEncoder() throws {
    let value: JSONValue = ["escapes": .string("\0\u{01}\u{08}\u{0c}\n\r\t\"\\é😀"), "other": [true, false, .null, -42, .number(0.25)]]
    let size = value.jsonString().utf8.count
    #expect(try fileResultSize(value, limit: size) == size)
    #expect(throws: ToolRunError.self) { try fileResultSize(value, limit: size - 1) }
    #expect(throws: ToolRunError.self) { try fileResultSize(.string(String(repeating: "\0", count: 16 << 20)), limit: 24 << 20) }
  }

  @Test func fileReadAndWriteBounds() async throws {
    try await withRig { rig in
      _ = try await rig.space.fs(.shared).write("/large", Data(repeating: 0, count: (16 << 20) + 1), ifMatch: nil)
      _ = try await rig.space.fs(.shared).write("/escaped", Data(repeating: 0, count: 16 << 20), ifMatch: nil)
      let result = try await rig.evaluate(#"""
      import {readBytes,readText,writeText} from 'wuhu:space'
      const codes=[]
      for(const call of [()=>readBytes('/large'),()=>readText('/escaped'),()=>writeText('/big','x'.repeat(16*1024*1024+1),{ifMatch:null})]) {
        try {await call();codes.push('ok')} catch(e) {codes.push(e.code)}
      }
      result(codes)
      """#)
      #expect(result == ["invalidArgument", "invalidArgument", "invalidArgument"])
    }
  }
}
