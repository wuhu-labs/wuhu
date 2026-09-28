import ClaudeStream
import JSONValue
import OrderedCollections
import Testing

// Bodies and entries as Claude Code 2.1.272 sent and logged them in
// a dev Mac's ~/wuhu-probe/loop5/run5, and 2.1.280 in the probe's failure scenario
// (the after-failed-tool ones), cut to the fields the loop reads plus neighbours.
@Suite struct ClaudeCodeHandoverTests {
  private static let afterTool = JSONValue.parse(#"""
  {"session_id":"4a9f8d33-c25a-4146-bec2-1100a7eae6c1","permission_mode":"dontAsk","hook_event_name":"PostToolUse","tool_name":"mcp__wuhu__echo","tool_input":{"text":"hi"},"tool_response":[{"type":"text","text":"ECHO"}],"tool_use_id":"toolu_p002","duration_ms":4}
  """#)!
  private static let afterFailedTool = JSONValue.parse(#"""
  {"session_id":"febf4806-15dc-4bc4-a7b8-1492c2ce39ac","permission_mode":"dontAsk","hook_event_name":"PostToolUseFailure","tool_name":"mcp__wuhu__fail","tool_input":{},"tool_use_id":"toolu_fail","error":"FAIL-1 refused","is_interrupt":false,"duration_ms":3,"mcp_server":{"name":"wuhu","source":"dynamic"}}
  """#)!
  private static let endOfTurn = JSONValue.parse(#"""
  {"session_id":"4a9f8d33-c25a-4146-bec2-1100a7eae6c1","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"REPLY-TO: PLAIN please","background_tasks":[],"session_crons":[]}
  """#)!
  private static let afterToolRecord = JSONValue.parse(#"""
  {"parentUuid":"bfb3","attachment":{"type":"hook_additional_context","content":["x"],"hookName":"PostToolUse:mcp__wuhu__echo","toolUseID":"toolu_p002","hookEvent":"PostToolUse"},"type":"attachment","uuid":"2607"}
  """#)!.object!
  private static let afterFailedToolRecord = JSONValue.parse(#"""
  {"parentUuid":"18d9","attachment":{"type":"hook_additional_context","content":["x"],"hookName":"PostToolUseFailure:mcp__wuhu__fail","toolUseID":"toolu_fail","hookEvent":"PostToolUseFailure"},"type":"attachment","uuid":"8439"}
  """#)!.object!
  private static let endOfTurnRecord = JSONValue.parse(#"""
  {"parentUuid":"9dc1","attachment":{"type":"hook_additional_context","content":["x"],"hookName":"Stop","toolUseID":"7f256e8a-2daf-4853-ad88-1429c6c614dd","hookEvent":"Stop"},"type":"attachment","uuid":"fc97"}
  """#)!.object!

  @Test func hooksAreReadFromTheirRequestBodies() {
    #expect(ClaudeCodeHook(body: Self.afterTool) == .afterTool(toolUseID: "toolu_p002", failed: false))
    #expect(ClaudeCodeHook(body: Self.afterFailedTool) == .afterTool(toolUseID: "toolu_fail", failed: true))
    #expect(ClaudeCodeHook(body: ["hook_event_name": "PostToolUseFailure"]) == nil)
    #expect(ClaudeCodeHook(body: Self.endOfTurn) == .endOfTurn(reentered: false))
    #expect(ClaudeCodeHook(body: ["hook_event_name": "Stop", "stop_hook_active": true]) == .endOfTurn(reentered: true))
    #expect(ClaudeCodeHook(body: ["hook_event_name": "PreToolUse", "tool_use_id": "t"]) == nil)
    #expect(ClaudeCodeHook(body: ["hook_event_name": "Stop"]) == nil)
  }

  @Test func everyHookHandsOverAsAdditionalContextAndOtherwiseSaysNothing() {
    let afterTool = ClaudeCodeHook.afterTool(toolUseID: "t", failed: false)
    #expect(afterTool.reply(handingOver: "hi") == ["hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": "hi"]])
    #expect(ClaudeCodeHook.afterTool(toolUseID: "t", failed: true).reply(handingOver: "hi") == [
      "hookSpecificOutput": ["hookEventName": "PostToolUseFailure", "additionalContext": "hi"],
    ])
    #expect(ClaudeCodeHook.endOfTurn(reentered: false).reply(handingOver: "hi") == [
      "hookSpecificOutput": ["hookEventName": "Stop", "additionalContext": "hi"],
    ])
    #expect(afterTool.reply(handingOver: nil) == [:])
  }

  @Test func eachHandoverIsConfirmedByItsOwnRecordOnly() {
    let afterTool = ClaudeCodeHook(body: Self.afterTool)!.record
    let afterFailedTool = ClaudeCodeHook(body: Self.afterFailedTool)!.record
    let endOfTurn = ClaudeCodeHook(body: Self.endOfTurn)!.record
    #expect(afterTool.isRecorded(by: Self.afterToolRecord))
    #expect(!afterTool.isRecorded(by: Self.endOfTurnRecord))
    #expect(!ClaudeCodeHook.afterTool(toolUseID: "toolu_other", failed: false).record.isRecorded(by: Self.afterToolRecord))
    #expect(afterFailedTool.isRecorded(by: Self.afterFailedToolRecord))
    #expect(!ClaudeCodeHook.afterTool(toolUseID: "toolu_fail", failed: false).record.isRecorded(by: Self.afterFailedToolRecord))
    #expect(!ClaudeCodeHook.afterTool(toolUseID: "toolu_p002", failed: true).record.isRecorded(by: Self.afterToolRecord))
    #expect(endOfTurn.isRecorded(by: Self.endOfTurnRecord))
    #expect(!endOfTurn.isRecorded(by: Self.afterToolRecord))

    let user = ClaudeCodeHandoverRecord.userEntry(uuid: "u-1")
    #expect(user.isRecorded(by: ["type": "user", "uuid": "u-1", "message": ["role": "user", "content": "x"]]))
    #expect(!user.isRecorded(by: ["type": "user", "uuid": "u-2"]))
    #expect(!user.isRecorded(by: ["type": "attachment", "uuid": "u-1"]))
  }

  @Test func aStandardInputMessageCarriesItsUUIDAndBlocksInOrder() {
    let line = claudeCodeUserMessage(uuid: "u-1", content: [.text("hello"), .image(mediaType: "image/png", base64: "AAAA")])
    #expect(line.last == UInt8(ascii: "\n"))
    #expect(JSONValue.parse(utf8: line.dropLast()) == [
      "type": "user",
      "uuid": "u-1",
      "session_id": "",
      "parent_tool_use_id": .null,
      "message": ["role": "user", "content": [
        ["type": "text", "text": "hello"],
        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]],
      ]],
    ])
  }
}
