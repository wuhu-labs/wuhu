import Foundation
import Testing
import WuhuRunner

struct WuhuRunnerConfigTests {
  @Test func loadsYAMLWithWorkspacesAndStartupScript() throws {
    let yaml = """
    name: runner-1
    connectTo: http://127.0.0.1:5530
    workspaces_path: /tmp/wuhu-workspaces
    databasePath: /tmp/runner.sqlite
    environments:
    - name: template
      type: folder-template
      path: /tmp/template
      startup_script: ./startup.sh
    """

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wuhu-runner-\(UUID().uuidString).yml")
    try yaml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let config = try WuhuRunnerConfig.load(path: tmp.path)
    #expect(config.name == "runner-1")
    #expect(config.connectTo == "http://127.0.0.1:5530")
    #expect(config.workspacesPath == "/tmp/wuhu-workspaces")
    #expect(config.databasePath == "/tmp/runner.sqlite")
    #expect(config.environments.count == 1)
    #expect(config.environments[0].name == "template")
    #expect(config.environments[0].type == "folder-template")
    #expect(config.environments[0].path == "/tmp/template")
    #expect(config.environments[0].startupScript == "./startup.sh")
  }
}
