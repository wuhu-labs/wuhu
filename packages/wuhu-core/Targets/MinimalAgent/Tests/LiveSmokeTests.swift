import Dependencies
import Fetch
import FetchURLSession
import Foundation
import JSONValue
import MinimalAgent
import Scratch
import Testing

// Opt-in, never in CI: runs only with WUHU_LIVE=1 and DEEPSEEK_API_KEY, e.g.
// bazel test //packages/wuhu-core:MinimalAgentTests --test_env=WUHU_LIVE=1 --test_env=DEEPSEEK_API_KEY
@Suite struct LiveSmokeTests {
  @Test func deepSeekFlashFixesAFileWithBashAndCompletes() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["WUHU_LIVE"] == "1", let key = environment["DEEPSEEK_API_KEY"] else { return }
    let folder = try ScratchFolder("minimal-agent-live")
    try "def add(a, b):\n    return a - b\n".write(to: folder.url.appending(path: "calc.py"), atomically: true, encoding: .utf8)
    let request: JSONValue = [
      "model": "deepseek/deepseek-flash",
      "provider": ["dialect": "anthropic", "baseURL": "https://api.deepseek.com/anthropic", "models": ["deepseek-flash": ["maxInput": 1_048_576, "maxOutput": 65536, "efforts": ["none", "low", "medium", "high"], "defaultEffort": "low"]]],
      "credential": ["apiKey": .string(key)],
      "system": "You are a careful coding agent working in the current directory.",
      "task": "calc.py has a bug in add. Fix it, then prove it with: python3 -c 'from calc import add; print(add(2, 3))'. Complete with the printed number.",
      "maxTurns": 12,
      "bashTimeoutSeconds": 30,
    ]
    let result = try await withDependencies {
      $0.fetch = .urlSession()
      $0.continuousClock = ContinuousClock()
    } operation: {
      try await MinimalAgent.run(request: request.jsonString(), log: .new("live.jsonl"), workingDirectory: folder.path)
    }
    #expect(result.contains("5"))
    #expect(try String(contentsOf: folder.url.appending(path: "calc.py"), encoding: .utf8).contains("a + b"))
  }
}
