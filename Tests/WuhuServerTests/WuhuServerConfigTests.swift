import Foundation
import Testing
import WuhuServer

struct WuhuServerConfigTests {
  @Test func loadsYAML() throws {
    let yaml = """
    llm:
      openai: sk-openai
      anthropic: sk-anthropic
    llm_request_log_dir: /tmp/wuhu-llm-logs
    runners:
    - name: runner-1
      address: 127.0.0.1:5531
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
    #expect(config.llmRequestLogDir == "/tmp/wuhu-llm-logs")
    #expect(config.host == "127.0.0.1")
    #expect(config.port == 5530)
    #expect(config.runners?.count == 1)
    #expect(config.runners?[0].name == "runner-1")
    #expect(config.runners?[0].address == "127.0.0.1:5531")
  }
}
