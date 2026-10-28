import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
@testable import ExecSupervisor
import InferenceKit
import JSONValue
import LoopCore
import MachineContract
import MainHub
import OperationRuntime
import Scratch
import Serve
import ServeTesting
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Synchronization
import TaskLifetime
import Testing
import WuhuAI

// The evergreen story: main owns the store and serves its API; workers run
// the loops, the tools and the scripts, and reach main only through it. A
// worker can be drained while its sessions are busy: each stops at the end
// of what cannot move (an inference, a script), lets go of what the next
// worker rejoins (an exec on a machine), and goes on there with the same
// transcript. The model is scripted; the server and the machine run in
// process; nothing is faked on main's side.
@Suite(.deterministicDependencies) struct EvergreenStoryTests {
  @Test(arguments: Pairing.allCases) func aSettledSessionGoesOnWhereItLeftOff(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let story = try await Story(pairing)
      story.script([.say("hello from A"), .say("hello from B")])
      let a = try await story.worker(), b = try await story.worker()
      try await story.running {
        let session = try await story.session()
        try await story.say("first", to: session)
        try await story.settled(session)
        #expect(a.inferences.count == 1 && b.inferences.isEmpty)

        try await story.drain(a)

        try await story.say("second", to: session)
        try await story.settled(session)
        #expect(a.inferences.count == 1 && b.inferences.count == 1)
        #expect(b.inferences.first?.assistantTexts == ["hello from A"])
        #expect(try await story.replies(session) == ["hello from A", "hello from B"])
      }
    }
  }

  // A turn with tools on both sides of the move: A writes a file and is
  // asked again with the result; the drain waits for that inference, which
  // ends in a read; B runs the read and the inference after it.
  @Test(arguments: Pairing.allCases) func aBusyTurnMovesWhenTheInferenceInFlightEnds(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let thinking = Gate()
      let story = try await Story(pairing)
      story.script([
        .call("write", ["path": "/story/note.md", "content": "kept"]),
        .held(thinking, .call("read", ["path": "/story/note.md"])),
        .say("done"),
      ])
      let a = try await story.worker(), b = try await story.worker()
      try await story.running {
        let session = try await story.session()
        try await story.say("go", to: session)
        try await until("A is asked with the write's result") { a.inferences.count == 2 }

        let moved = story.draining(a)
        try await ContinuousClock().sleep(for: .milliseconds(50))
        #expect(!moved.isOpen, "the drain waits for the inference in flight")
        thinking.open()
        await moved.wait()

        try await story.settled(session)
        #expect(a.inferences.count == 2 && b.inferences.count == 1)
        let told = try await story.transcript(session)
        #expect(told == ["hears", "calls write", "result", "calls read", "result", "says"], "\(told)")
        #expect(try await story.failures(session).isEmpty)
        #expect(try await story.replies(session) == ["done"])
      }
    }
  }

  // The exec keeps running on the machine: A lets go of its wait at once,
  // the call stays pending, B rejoins the same exec by the call id and gets
  // its exit.
  @Test(arguments: Pairing.allCases) func anExecHandsOffAtOnceAndTheNextWorkerRejoinsIt(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let story = try await Story(pairing)
      let a = try await story.worker(), b = try await story.worker()
      try await story.running {
        let box = try await story.machine()
        story.script([
          .call("exec", [
            "machine": .string(box.id.rawValue), "cwd": .string(box.folder),
            "command": "echo started; touch started; sleep 1; echo finished", "wait_seconds": 30,
          ]),
          .say("done"),
        ])
        let session = try await story.session()
        try await story.say("run", to: session)
        let exec = try await story.liveExec(of: session)
        try await until("the command runs on the machine") { FileManager.default.fileExists(atPath: box.folder + "/started") }

        let clock = ContinuousClock()
        let started = clock.now
        try await story.drain(a)
        let took = clock.now - started
        let afterDrain = try await story.space.execRecord(exec)
        #expect(afterDrain?.terminal == nil, "the drain did not wait for the exec: \(took), released \(a.released), \(String(describing: afterDrain))")

        try await story.settled(session)
        #expect(a.inferences.count == 1 && b.inferences.count == 1)
        let told = try await story.transcript(session)
        #expect(told == ["hears", "calls exec", "result", "says"], "\(told)")
        #expect(try await story.execOutputs(session) == ["started\nfinished\n"])
        let ended = try await story.space.execRecord(exec)
        #expect(ended?.terminal == .exited(code: 0) && ended?.toolCallID != nil, "the same exec ended: \(String(describing: ended))")
      }
    }
  }

  // The exec call returned `running` and the turn ended; the exec still runs
  // on the machine when A is drained. A lets go of it without a word, B
  // takes it up when the session mounts there, and its end arrives once, on B.
  @Test(arguments: Pairing.allCases) func aRunningExecGoesWithItsSession(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let story = try await Story(pairing)
      let a = try await story.worker(), b = try await story.worker()
      try await story.running {
        let box = try await story.machine()
        story.script([
          .call("exec", [
            "machine": .string(box.id.rawValue), "cwd": .string(box.folder),
            "command": "echo started; touch started; while [ ! -e go ]; do sleep 0.05; done; echo finished", "wait_seconds": 1,
          ]),
          .say("waiting"),
          .say("done"),
        ])
        let session = try await story.session()
        try await story.say("run", to: session)
        let exec = try await story.liveExec(of: session)
        try await story.settled(session)
        #expect(try await story.replies(session) == ["waiting"])

        try await story.drain(a)
        #expect(try await story.space.execRecord(exec)?.terminal == nil, "the exec outlives the drain")
        #expect(try await a.line.runningWork(session).isEmpty, "A let go of the exec")
        try await until("B follows the exec") { try await b.line.runningWork(session) == [execHandle(exec)] }
        FileManager.default.createFile(atPath: box.folder + "/go", contents: nil)

        try await until("the end arrives and B answers it") { try await story.replies(session) == ["waiting", "done"] }
        try await story.settled(session)
        #expect(a.inferences.count == 2 && b.inferences.count == 1)
        let told = try await story.transcript(session)
        #expect(told == ["hears", "calls exec", "result", "says", "hears the exec end", "says"], "\(told)")
        let notices = try await story.execEnds(session)
        #expect(notices.count == 1 && notices.first?.hasSuffix("started\nfinished\n") == true, "\(notices)")
      }
    }
  }

  // A worker that comes up while main runs takes sessions as one that was
  // there from the start does.
  @Test(arguments: Pairing.allCases) func aWorkerThatComesUpLaterTakesTheSessions(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let story = try await Story(pairing)
      story.script([.say("hello from A"), .say("hello from B")])
      let a = try await story.worker()
      try await story.running {
        let session = try await story.session()
        try await story.say("first", to: session)
        try await story.settled(session)

        let b = try await story.worker()
        try await story.drain(a)

        try await story.say("second", to: session)
        try await story.settled(session)
        #expect(a.inferences.count == 1 && b.inferences.count == 1)
        #expect(try await story.replies(session) == ["hello from A", "hello from B"])
      }
    }
  }

  // A script runs in its worker's JavaScript runtime and cannot move: the
  // drain waits for the call to answer, then the session goes on with it.
  @Test(arguments: Pairing.allCases) func aScriptEndsHereBeforeItsSessionMoves(_ pairing: Pairing) async throws {
    try await withSessionDeps {
      let story = try await Story(pairing)
      story.script([
        .call("run_script", ["source": "await new Promise((go) => setTimeout(go, 500)); result('ran')", "wait_seconds": 30]),
        .say("done"),
      ])
      let a = try await story.worker(), b = try await story.worker()
      try await story.running {
        let session = try await story.session()
        try await story.say("script", to: session)
        try await until("A runs the script") { await a.scripts == 1 }

        let moved = story.draining(a)
        try await ContinuousClock().sleep(for: .milliseconds(50))
        let stillRunning = await a.scripts == 1
        #expect(!moved.isOpen && stillRunning, "the drain waits for the script")
        await moved.wait()

        try await story.settled(session)
        #expect(a.inferences.count == 1 && b.inferences.count == 1)
        let told = try await story.transcript(session)
        #expect(told == ["hears", "calls run_script", "result", "says"], "\(told)")
        #expect(try await story.scriptOutputs(session).first?.contains("ran") == true)
        #expect(try await story.replies(session) == ["done"])
      }
    }
  }
}
