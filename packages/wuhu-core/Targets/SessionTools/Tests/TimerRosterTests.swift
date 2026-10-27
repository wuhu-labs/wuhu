import DeterministicDependencies
import JSONValue
@testable import SessionTools
import Testing

@Suite(.deterministicDependencies) struct TimerRosterTests {
  @Test func timerSchemaDeclaresOneShotCronAndHandlerParameters() throws {
    let tool = try #require(ToolExecutor.tools.first {
      if case .function("timer", _, _) = $0 { return true }; return false
    })
    guard case let .function(_, _, parameters) = tool,
          case let .object(schema) = parameters,
          case let .object(properties)? = schema["properties"]
    else {
      Issue.record("timer parameter schema is missing"); return
    }
    #expect(Set(properties.keys) == ["message", "in_seconds", "cron", "handler", "name"])
    #expect(properties["cron"]?.object?["type"] == "string")
    #expect(schema["required"] == .array(["message"]))
    #expect(schema["additionalProperties"] == false)
  }
}
