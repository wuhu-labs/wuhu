import ArgumentParser
import Testing
@testable import wuhu

struct WuhuCLITests {
  @Test func resolveWuhuSessionId_prefersOptionOverEnv() throws {
    let resolved = try resolveWuhuSessionId("opt_123", env: ["WUHU_CURRENT_SESSION_ID": "env_456"])
    #expect(resolved == "opt_123")
  }

  @Test func resolveWuhuSessionId_usesEnvWhenOptionMissing() throws {
    let resolved = try resolveWuhuSessionId(nil, env: ["WUHU_CURRENT_SESSION_ID": "env_456"])
    #expect(resolved == "env_456")
  }

  @Test func resolveWuhuSessionId_throwsWhenMissing() {
    #expect(throws: ValidationError.self) {
      _ = try resolveWuhuSessionId(nil, env: [:])
    }
  }

  @Test func resolveWuhuUsername_prefersOptionOverEnv() {
    let resolved = resolveWuhuUsername("opt_user", env: ["WUHU_USERNAME": "env_user"])
    #expect(resolved == "opt_user")
  }

  @Test func resolveWuhuUsername_usesEnvWhenOptionMissing() {
    let resolved = resolveWuhuUsername(nil, env: ["WUHU_USERNAME": "env_user"])
    #expect(resolved == "env_user")
  }
}
