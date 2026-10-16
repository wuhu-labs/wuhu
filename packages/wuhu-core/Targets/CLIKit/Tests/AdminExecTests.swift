@testable import CLIKit
import Fetch
import Synchronization
import Testing

@Suite struct AdminExecCLITests {
  @Test func adminExecRemainsExplicitWithWorkerDefault() throws {
    guard case let .serve(defaults) = try Command.parse(["serve", "/tmp/space"]),
          case let .serve(enabled) = try Command.parse(["serve", "/tmp/space", "--admin-exec"]) else { Issue.record("Expected serve"); return }
    guard case let .serve(explicit) = try Command.parse(["serve", "/tmp/space", "--execution-placement", "worker", "--admin-exec"]) else { Issue.record("Expected serve"); return }
    #expect(explicit == enabled)
    #expect(!defaults.adminExec)
    #expect(enabled.adminExec && enabled.executionPlacement == .worker)
    #expect(throws: (any Error).self) { try Command.parse(["serve", "/tmp/space", "--execution-placement", "in-process", "--admin-exec"]) }
    #expect(try Command.parse(["admin-exec", "/tmp/space", "--rollback"]) == .adminExec(folder: "/tmp/space", rollback: true))
    #expect(throws: (any Error).self) { try Command.parse(["admin-exec", "/tmp/space", "--binary", "/tmp/other"]) }
  }

  @Test func productionCLIHasNoTestPolicySelector() throws {
    for flag in ["--admin-exec-policy", "--test-policy", "--allowed-uids"] {
      #expect(throws: (any Error).self) { try Command.parse(["serve", "/tmp/space", "--execution-placement", "worker", "--admin-exec", flag, "/tmp/forged-policy"]) }
      #expect(throws: (any Error).self) { try Command.parse(["admin-exec", "/tmp/space", flag, "/tmp/forged-policy"]) }
    }
  }

  @Test(arguments: [false, true]) func agentExecCannotEnableOrTriggerEvenWithWalletOverride(wallet: Bool) async {
    let calls = Mutex(0)
    var environment = ["WUHU_EXEC": "1", "WUHU_TOKEN": "wst_fixture", "WUHU_SPACE_URL": "https://session.test"]
    if wallet { environment["WUHU_IDENTITY"] = "wallet" }
    let runner = CommandRunner(fetch: .init { _ in calls.withLock { $0 += 1 }; return Response(status: .ok) }, serve: { _ in calls.withLock { $0 += 1 } }, adminExec: { _, _ in calls.withLock { $0 += 1 } }, stdin: { "" }, stdout: { _ in }, stderr: { _ in }, environment: environment, currentDirectory: "/")
    #expect(await runner.run(arguments: ["serve", "/tmp/space", "--execution-placement", "worker", "--admin-exec"]) != 0)
    #expect(await runner.run(arguments: ["admin-exec", "/tmp/space"]) != 0)
    #expect(await runner.run(arguments: ["admin-exec", "/tmp/space", "--rollback"]) != 0)
    #expect(calls.withLock { $0 } == 0)
  }

  @Test func deploymentRequestsUseLocalHandlerBeforeWalletOrNetworkResolution() async {
    let effects = Mutex<[String]>([])
    let runner = CommandRunner(fetch: .init { _ in effects.withLock { $0.append("network") }; return Response(status: .ok) }, adminExec: { folder, rollback in effects.withLock { $0.append(folder + (rollback ? ":rollback" : ":exec")) } }, stdin: { "" }, stdout: { _ in }, stderr: { _ in }, environment: [:], currentDirectory: "/")
    #expect(await runner.run(arguments: ["admin-exec", "/tmp/space"]) == 0)
    #expect(await runner.run(arguments: ["admin-exec", "/tmp/space", "--rollback"]) == 0)
    #expect(effects.withLock { $0 } == ["/tmp/space:exec", "/tmp/space:rollback"])
  }

  @Test func requestHasNoRemoteOrScriptFallback() async {
    let network = Mutex(0)
    let runner = CommandRunner(fetch: .init { _ in network.withLock { $0 += 1 }; return Response(status: .ok) }, stdin: { "" }, stdout: { _ in }, stderr: { _ in }, environment: [:], currentDirectory: "/")
    #expect(await runner.run(arguments: ["admin-exec", "/tmp/space"]) != 0)
    #expect(await runner.run(arguments: ["admin-exec", "/tmp/space", "--rollback"]) != 0)
    #expect(network.withLock { $0 } == 0)
  }
}
