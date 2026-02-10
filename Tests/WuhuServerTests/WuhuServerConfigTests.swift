import Foundation
import Testing
import WuhuServer

struct WuhuServerConfigTests {
  @Test func loadsYAML() throws {
    let yaml = """
    llm:
      openai: sk-openai
      anthropic: sk-anthropic
    environments:
    - name: wuhu-repo
      type: local
      path: /tmp/wuhu
    databasePath: /tmp/wuhu.sqlite
    host: 127.0.0.1
    port: 5530
    """

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-server-\(UUID().uuidString).yml")
    try yaml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = try WuhuServerConfig.load(path: tmp.path)
    #expect(config.llm?.openai == "sk-openai")
    #expect(config.llm?.anthropic == "sk-anthropic")
    #expect(config.databasePath == "/tmp/wuhu.sqlite")
    #expect(config.host == "127.0.0.1")
    #expect(config.port == 5530)
    #expect(config.environments.count == 1)
    #expect(config.environments[0].name == "wuhu-repo")
    #expect(config.environments[0].type == "local")
    #expect(config.environments[0].path == "/tmp/wuhu")
  }
}
