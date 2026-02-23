import Foundation
import Testing
import WuhuRunner

struct WuhuRunnerConfigTests {
  @Test func loadsYAML() throws {
    let yaml = """
    name: runner-1
    connectTo: http://127.0.0.1:5530
    databasePath: /tmp/runner.sqlite
    listen:
      host: 127.0.0.1
      port: 5531
    """

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-runner-\(UUID().uuidString).yml")
    try yaml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = try WuhuRunnerConfig.load(path: tmp.path)
    #expect(config.name == "runner-1")
    #expect(config.connectTo == "http://127.0.0.1:5530")
    #expect(config.databasePath == "/tmp/runner.sqlite")
    #expect(config.listen?.host == "127.0.0.1")
    #expect(config.listen?.port == 5531)
  }
}
