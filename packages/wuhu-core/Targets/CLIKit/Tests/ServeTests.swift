@testable import CLIKit
import Fetch
import Testing

@Suite
struct ServeParsingTests {
  @Test func defaultsPortsAndFlags() throws {
    #expect(try Command.parse(["serve", "/tmp/store"]) == .serve(ServeCommand(
      folder: "/tmp/store", host: "127.0.0.1", port: 5540, webPort: 5541, webOrigin: nil, dev: false, devImport: nil, devExport: nil,
      certificate: nil, privateKey: nil,
    )))
  }

  @Test func webPortDefaultFollowsPort() throws {
    #expect(try Command.parse(["serve", "store", "--port", "7000"]) == .serve(ServeCommand(
      folder: "store", host: "127.0.0.1", port: 7000, webPort: 7001, webOrigin: nil, dev: false, devImport: nil, devExport: nil,
      certificate: nil, privateKey: nil,
    )))
  }

  @Test func parsesHostOptionForLANOptIn() throws {
    #expect(try Command.parse(["serve", "store", "--host", "0.0.0.0"]) == .serve(ServeCommand(
      folder: "store", host: "0.0.0.0", port: 5540, webPort: 5541, webOrigin: nil, dev: false, devImport: nil, devExport: nil,
      certificate: nil, privateKey: nil,
    )))
  }

  @Test func parsesEveryOption() throws {
    let arguments = [
      "serve", "--port", "7000", "--web-port", "7100", "--dev", "--public-read",
      "--dev-import", "/in", "--dev-export", "/out",
      "--origin", "https://api.wuhu.example:7443",
      "--web-origin", "https://web.wuhu.example",
      "--cert", "/tls/cert.pem", "--key", "/tls/key.pem",
      "--group-certificate", "/tls/groups.pem", "--group-private-key", "/tls/groups.key",
      "--web-app", "/spa/dist", "store",
    ]
    #expect(try Command.parse(arguments) == .serve(ServeCommand(
      folder: "store", host: "127.0.0.1", port: 7000, origin: "https://api.wuhu.example:7443", webPort: 7100, webOrigin: "https://web.wuhu.example", dev: true, publicRead: true, devImport: "/in", devExport: "/out",
      certificate: "/tls/cert.pem", privateKey: "/tls/key.pem",
      groupCertificate: "/tls/groups.pem", groupPrivateKey: "/tls/groups.key", webApp: "/spa/dist",
    )))
  }

  @Test func originIsNormalizedToABareOrigin() throws {
    guard case let .serve(command) = try Command.parse(["serve", "--origin", "https://api.wuhu.example/", "store"]) else {
      Issue.record("expected a serve command")
      return
    }
    #expect(command.origin == "https://api.wuhu.example")
  }

  @Test func publicReadParsesWithoutDev() throws {
    #expect(try Command.parse(["serve", "--public-read", "store"]) == .serve(ServeCommand(
      folder: "store", host: "127.0.0.1", port: 5540, webPort: 5541, webOrigin: nil, dev: false, publicRead: true, devImport: nil, devExport: nil,
      certificate: nil, privateKey: nil,
    )))
  }

  @Test(arguments: [
    ["serve"],
    ["serve", "store", "extra"],
    ["serve", "--port", "nope", "store"],
    ["serve", "--web-port", "nope", "store"],
    ["serve", "--dev-import", "store"],
    ["serve", "--web-app", "store"],
    ["serve", "--cert", "/tls/cert.pem", "store"],
    ["serve", "--key", "/tls/key.pem", "store"],
    ["serve", "--web-origin", "http://plain.example", "store"],
    ["serve", "--web-origin", "not a url", "store"],
    ["serve", "--origin", "http://plain.example", "store"],
    ["serve", "--origin", "not a url", "store"],
    ["serve", "--origin", "https://api.wuhu.example/deep/path", "store"],
    ["serve", "--origin", "https://api.wuhu.example?query=1", "store"],
    ["serve", "--origin", "https://api.wuhu.example", "--group-certificate", "/tls/groups.pem", "store"],
    ["serve", "--origin", "https://api.wuhu.example", "--group-private-key", "/tls/groups.key", "store"],
    ["serve", "--group-certificate", "/tls/groups.pem", "--group-private-key", "/tls/groups.key", "store"],
    [
      "serve", "--origin", "https://api.wuhu.example",
      "--group-certificate", "/tls/groups.pem", "--group-private-key", "/tls/groups.key", "store",
    ],
  ])
  func usageErrors(_ arguments: [String]) {
    #expect(throws: UsageError.self) {
      try Command.parse(arguments)
    }
  }
}

@Suite
struct ServeRoutingTests {
  private actor Received {
    var configs: [ServeCommand] = []
    var stderr = ""

    func record(_ config: ServeCommand) { self.configs.append(config) }
    func append(_ text: String) { self.stderr += text }
  }

  private func runner(_ received: Received, serve: (@Sendable (ServeCommand) async throws -> Void)?) -> CommandRunner {
    CommandRunner(
      fetch: FetchClient { _ in Response(status: .ok) },
      serve: serve,
      stdin: { "" },
      stdout: { _ in },
      stderr: { text in await received.append(text) },
      environment: [:],
      currentDirectory: "/",
    )
  }

  @Test func routesParsedConfigToInjectedHandlerAfterStartupLine() async throws {
    let received = Received()
    let runner = self.runner(received) { config in await received.record(config) }
    #expect(await runner.run(arguments: ["serve", "/tmp/store", "--dev"]) == 0)
    #expect(await received.configs == [ServeCommand(
      folder: "/tmp/store", host: "127.0.0.1", port: 5540, webPort: 5541, webOrigin: nil, dev: true, devImport: nil, devExport: nil,
      certificate: nil, privateKey: nil,
    )])
    #expect(await received.stderr == "serving /tmp/store on 127.0.0.1:5540 (api) and 127.0.0.1:5541 (web)\n")
  }

  @Test func usageErrorExitsSixtyFourWithoutReachingHandler() async throws {
    let received = Received()
    let runner = self.runner(received) { config in await received.record(config) }
    #expect(await runner.run(arguments: ["serve"]) == 64)
    #expect(await received.configs.isEmpty)
  }

  @Test func missingHandlerFailsWithoutStartupLine() async throws {
    let received = Received()
    let runner = self.runner(received, serve: nil)
    #expect(await runner.run(arguments: ["serve", "store"]) == 1)
    #expect(await received.stderr == "serve is not available in this client\n")
  }

  @Test func handlerErrorExitsOne() async throws {
    let received = Received()
    let runner = self.runner(received) { _ in throw CLIError(message: "bind failed") }
    #expect(await runner.run(arguments: ["serve", "store"]) == 1)
    #expect(await received.stderr.hasSuffix("bind failed\n"))
  }
}
