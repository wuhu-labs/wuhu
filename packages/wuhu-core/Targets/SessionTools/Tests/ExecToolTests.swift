import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import enum MachineContract.ExecTimeout
import enum MachineContract.ExitStatus
import MainHub
import OperationProtocol
import SessionDomain
@testable import SessionTools
@testable import SpaceCore
@testable import SpaceServer
import Testing
import struct WuhuAI.ToolArguments
import struct WuhuAI.ToolCall

@Suite(.deterministicDependencies) struct ExecToolTests {
  private func plan(_ extra: [String: JSONValue] = [:]) throws -> ExecToolPlan {
    var args: [String: JSONValue] = ["machine": "box", "cwd": "/work", "command": "printf done"]
    args.merge(extra) { _, new in new }
    return try ExecToolPlan(ToolCall(id: "tc-exec", name: "exec", arguments: ToolArguments(.object(.init(uniqueKeysWithValues: args)))))
  }

  private func end(status: ExitStatus? = .exited(code: 0), error: OperationError? = nil, text: String = "", cursor: Int? = nil, cut: Bool = false, timedOut: ExecTimeout? = nil) -> ExecFinished {
    ExecFinished(id: "ex_test", status: status, error: error, tail: Data(text.utf8), cursor: cursor ?? text.utf8.count, cut: cut, timedOut: timedOut)
  }

  @Test func execContextCarriesRepositoryInstructionsOnce() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      let session = try await makeSession(space)
      let machine = try await space.addMachine(name: "box").id
      let files = FakeMachineFS()
      files.put("/work/.git/HEAD", "ref: refs/heads/main", mtime: 1)
      files.put("/work/AGENTS.md", "repo manual", mtime: 1)
      let executor = try await loop.executor(owner: loop.hub { Hub(space: space, machines: files.seam) })
      let first = try #require(await executor.execContext(session, machine: machine, cwd: "/work", state: .init()))
      #expect(first.text.contains("repo manual"))
      let state = ToolExecutionState(folderRoots: first.folders, deliveredContext: first.deliveredContext ?? [:])
      let second = await executor.execContext(session, machine: machine, cwd: "/work", state: state)
      #expect(second?.text.isEmpty != false)
    }
  }

  @Test func envAndSecretNamesArePreservedWithoutResolvingValues() throws {
    let plan = try plan(["env": ["CI": "1"], "secrets": ["TOKEN": "GITHUB_TOKEN"]])
    #expect(plan.machine == "box")
    #expect(plan.cwd == "/work")
    #expect(plan.argv == ["sh", "-c", "printf done"])
    #expect(plan.env == ["CI": "1"])
    #expect(plan.secrets == ["TOKEN": "GITHUB_TOKEN"])
    #expect(plan.lifetime == 1800)
    #expect(plan.wait == 300)
    #expect(plan.maxOutput == 1 << 20)
  }

  @Test func aVariableSetTwiceIsRejectedWithoutDisclosingItsValue() throws {
    do {
      _ = try plan(["env": ["TOKEN": "plain"], "secrets": ["TOKEN": "GITHUB_TOKEN"]])
      Issue.record("overlapping env and secrets accepted")
    } catch let failure as ToolProblem {
      #expect(failure.message.contains("TOKEN"))
      #expect(!failure.message.contains("plain"))
    }
  }

  @Test(arguments: ["work", "../work", ""])
  func execRefusesARelativeWorkingDirectory(_ cwd: String) throws {
    #expect(throws: ToolProblem.self) { try plan(["cwd": .string(cwd)]) }
  }

  @Test func schemaAndMachineAddressAreValidated() throws {
    #expect(throws: ToolProblem.self) { try plan(["command": 42]) }
    #expect(throws: ToolProblem.self) { try plan(["machine": "machines://box/work"]) }
  }

  @Test func oldNameAndOutOfRangeValuesAreRejected() throws {
    let cases: [(String, JSONValue, String)] = [
      ("timeout_seconds", 30, "exec: timeout_seconds is renamed to max_lifetime_seconds"),
      ("max_lifetime_seconds", 14400.5, "exec: max_lifetime_seconds must be more than 0 and at most 14400"),
      ("max_lifetime_seconds", 1e300, "exec: max_lifetime_seconds must be more than 0 and at most 14400"),
      ("max_lifetime_seconds", 0, "exec: max_lifetime_seconds must be more than 0 and at most 14400"),
      ("wait_seconds", 0, "exec: wait_seconds must be more than 0"),
      ("max_output", 0, "exec: max_output must be more than 0"),
    ]
    for (key, value, message) in cases {
      do { _ = try plan([key: value]); Issue.record("\(key) accepted \(value)") }
      catch let failure as ToolProblem {
        #expect(failure.message == message)
        #expect(failure.code == "invalidArgument")
      }
    }
  }

  @Test func budgetsAreCappedAndCwdIsNormalized() throws {
    let plan = try plan(["cwd": "/work/./folder/..", "max_output": 1e9, "max_lifetime_seconds": 30, "wait_seconds": 20000])
    #expect(plan.cwd == "/work")
    #expect(plan.maxOutput == 4 << 20)
    #expect(plan.wait == 40)
  }

  @Test func hugeOutputIsTailClampedForTheTranscript() throws {
    let chatty = (1 ... 6000).map { "line-\($0)" }.joined(separator: "\n")
    guard case let .exec(result) = try plan().finished(end(text: chatty)) else { throw Mismatch("exec rendering failed") }
    #expect(result.exitCode == 0)
    #expect(result.output.contains("line-6000"))
    #expect(!result.output.contains("line-1\n"))
    #expect(result.output.hasSuffix("[showing the tail of \(chatty.utf8.count) bytes of output]"))
    #expect(result.output.utf8.count < 60 << 10)
  }

  @Test(arguments: [nil, 30, 14400] as [Double?])
  func aKilledExecSaysWhichLifetimeEndedIt(_ explicit: Double?) throws {
    let plan = try plan(explicit.map { ["max_lifetime_seconds": .number($0)] } ?? [:])
    guard case let .exec(result) = plan.finished(end(status: .signaled(signal: 15), text: "working\n", timedOut: .killed)) else { throw Mismatch("timeout rendering failed") }
    let note = explicit == nil
      ? "[killed after 1800 s, the default max lifetime; start longer work detached and watch it from run_script]"
      : "[killed after \(Int(explicit!)) s, its max_lifetime_seconds]"
    #expect(result.output == "working\n\n" + note)
    #expect(result.exitCode == 143)
  }

  @Test func anExitWithoutATimeoutVerdictCarriesNoLifetimeNote() throws {
    guard case let .exec(result) = try plan().finished(end()) else { throw Mismatch("exit rendering failed") }
    #expect(result.output == "")
    #expect(result.exitCode == 0)
  }

  @Test func anUnknownStatusIsATypedFailure() throws {
    let error = OperationError(.requestDeadline, message: "process status never came back")
    guard case let .failure(failure) = try plan().finished(end(status: nil, error: error, timedOut: .statusUnknown)) else { throw Mismatch("unknown status rendering failed") }
    #expect(failure.code == "requestDeadline")
    #expect(failure.message == error.message)
  }

  @Test func cutAndRetainedTailExplainTheLostHead() throws {
    guard case let .exec(result) = try plan(["max_output": 100]).finished(end(status: .signaled(signal: 9), text: "tail", cursor: 100, cut: true)) else { throw Mismatch("cut rendering failed") }
    #expect(result.exitCode == 137)
    #expect(result.output.contains("[showing the tail of 100 bytes of output]"))
    #expect(result.output.contains("[output was cut when the command stopped]"))
    #expect(result.output.contains("[output hit the 100-byte budget; the command was killed]"))
  }

  @Test(arguments: [WaitCut.waited(10), .arrival])
  func runningAnswersCarryTheHandleAndWaitReason(_ cut: WaitCut) throws {
    guard case let .exec(result) = try plan().running("ex_test", tail: Data("working".utf8), cut: cut),
          let value = JSONValue.parse(result.output)?.object else { throw Mismatch("running rendering failed") }
    #expect(value["status"] == "running")
    #expect(value["id"] == "exec.ex_test")
    #expect(value["tail"] == "working")
    #expect(value["note"]?.stringValue?.contains(cut.reason) == true)
    #expect(value["note"]?.stringValue?.contains("cancel") == true)
  }
}
