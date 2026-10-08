@testable import CLIKit
import Fetch
import Testing

@Suite
struct ServeParsingTests {
  @Test func defaultsPortsAndFlags() throws {
    #expect(try Command.parse(["serve", "/tmp/store"]) == .serve(ServeCommand(
      folder: "/tmp/store", host: "127.0.0.1", port: 5530, dev: false, devImport: nil, devExport: nil,
      certificate: nil, privateKey: nil,
    )))
  }

  @Test func parsesThePort() throws {
    #expect(try Command.parse(["serve", "store", "--port", "7000"]) == .serve(ServeCommand(
      folder: "store", host: "127.0.0.1", port: 7000, dev: false, devImport: nil, devExport: nil,
      certificate: nil, privateKey: nil,
    )))
  }

  @Test func parsesHostOptionForLANOptIn() throws {
    #expect(try Command.parse(["serve", "store", "--host", "0.0.0.0"]) == .serve(ServeCommand(
      folder: "store", host: "0.0.0.0", port: 5530, dev: false, devImport: nil, devExport: nil,
      certificate: nil, privateKey: nil,
    )))
  }

  @Test func parsesEveryOption() throws {
    let arguments = [
      "serve", "--port", "7000", "--dev", "--public-read",
      "--dev-import", "/in", "--dev-export", "/out",
      "--origin", "https://api.wuhu.example:7443",
      "--cert", "/tls/cert.pem", "--key", "/tls/key.pem",
      "--group-certificate", "/tls/groups.pem", "--group-private-key", "/tls/groups.key",
      "--web-app", "/spa/dist", "store",
    ]
    #expect(try Command.parse(arguments) == .serve(ServeCommand(
      folder: "store", host: "127.0.0.1", port: 7000, origin: "https://api.wuhu.example:7443", dev: true, publicRead: true, devImport: "/in", devExport: "/out",
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
      folder: "store", host: "127.0.0.1", port: 5530, dev: false, publicRead: true, devImport: nil, devExport: nil,
      certificate: nil, privateKey: nil,
    )))
  }

  @Test func deprecatedWebOptionsParseAndAreIgnored() throws {
    let arguments = ["serve", "--web-port", "5531", "--web-origin", "https://web.wuhu.example", "store"]
    #expect(try Command.parse(arguments) == .serve(ServeCommand(
      folder: "store", host: "127.0.0.1", port: 5530, dev: false, devImport: nil, devExport: nil,
      certificate: nil, privateKey: nil, ignoredOptions: ["--web-port", "--web-origin"],
    )))
  }

  @Test func anIPLiteralOriginPointsToAnSslipName() {
    #expect {
      try Command.parse(["serve", "--origin", "https://192.168.1.5:5530", "store"])
    } throws: { error in
      (error as? UsageError)?.message.contains("sslip.io") == true
    }
  }

  @Test(arguments: [
    ["serve"],
    ["serve", "store", "extra"],
    ["serve", "--port", "nope", "store"],
    ["serve", "--web-port", "store"],
    ["serve", "--dev-import", "store"],
    ["serve", "--web-app", "store"],
    ["serve", "--cert", "/tls/cert.pem", "store"],
    ["serve", "--key", "/tls/key.pem", "store"],
    ["serve", "--origin", "https://192.168.1.5:5530", "store"],
    ["serve", "--origin", "https://[::1]:5530", "store"],
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
      folder: "/tmp/store", host: "127.0.0.1", port: 5530, dev: true, devImport: nil, devExport: nil,
      certificate: nil, privateKey: nil,
    )])
    #expect(await received.stderr == "serving /tmp/store on 127.0.0.1:5530 at https://localhost:5530\n")
  }

  @Test func eachDeprecatedWebOptionWarnsOnceAndServes() async throws {
    let received = Received()
    let runner = self.runner(received) { config in await received.record(config) }
    let arguments = ["serve", "/tmp/store", "--web-port", "5531", "--web-origin", "https://web.example", "--origin", "https://space.example"]
    #expect(await runner.run(arguments: arguments) == 0)
    #expect(await received.configs.count == 1)
    #expect(await received.stderr == """
    --web-port is ignored: content is served on <group>.<host> on the one port; remove it
    --web-origin is ignored: content is served on <group>.<host> on the one port; remove it
    serving /tmp/store on 127.0.0.1:5530 at https://space.example

    """)
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

@Suite struct FlatServeParsingTests {
  @Test func parsesTheFlatTemplate() throws {
    guard case let .serve(config) = try Command.parse([
      "serve", "store", "--origin", "https://alex.test:5530", "--content-host-pattern", "{group}--alex.test:5530",
    ]) else { Issue.record("expected serve"); return }
    #expect(config.contentHostPattern == "{group}--alex.test:5530")
  }

  @Test(arguments: [
    ["serve", "store", "--content-host-pattern", "{group}--alex.test"],
    ["serve", "store", "--origin", "https://alex.test", "--content-host-pattern", "{group}--alex.test:5530"],
    ["serve", "store", "--origin", "https://alex.test", "--content-host-pattern", "{group}--alex.test", "--cert", "cert", "--key", "key", "--group-certificate", "gc", "--group-private-key", "gk"],
  ]) func rejectsInvalidConfiguration(arguments: [String]) {
    #expect(throws: UsageError.self) { try Command.parse(arguments) }
  }
}
