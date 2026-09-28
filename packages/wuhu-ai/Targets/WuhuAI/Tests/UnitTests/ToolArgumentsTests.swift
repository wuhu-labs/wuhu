import Foundation
import JSONValue
import Testing
import WuhuAI

@Suite struct ToolArgumentsTests {
  @Test func `emitted argument bytes survive a Codable round trip`() throws {
    let emitted = #"{"command":"bash -lc 'ls -la'", "max_output":30000,"timeout_seconds":30}"#
    let call = ToolCall(id: "call_1", name: "exec", arguments: try #require(ToolArguments(verbatim: emitted)))
    let encoded = try JSONEncoder().encode(call)
    let decoded = try JSONDecoder().decode(ToolCall.self, from: encoded)
    #expect(decoded.arguments.text == emitted)
    #expect(decoded.arguments.json.object?["max_output"] == .integer(30000))
  }

  @Test func `a stored row from before verbatim arguments still decodes`() throws {
    let legacy = #"{"id":"call_1","name":"exec","arguments":{"max_output":30000,"command":"ls"}}"#
    let decoded = try JSONDecoder().decode(ToolCall.self, from: Data(legacy.utf8))
    #expect(decoded.arguments.text == #"{"command":"ls","max_output":30000}"#)
    #expect(decoded.arguments.json.object?["command"] == .string("ls"))
  }

  @Test func `arguments we synthesize serialize sorted`() {
    #expect(ToolArguments.object(["zeta": .integer(1), "alpha": .integer(2)]).text == #"{"alpha":2,"zeta":1}"#)
  }

  @Test func `only object-shaped text is arguments`() {
    #expect(ToolArguments(verbatim: "not json") == nil)
    #expect(ToolArguments(verbatim: "[1,2]") == nil)
    #expect(ToolArguments(verbatim: "{}")?.text == "{}")
  }
}
