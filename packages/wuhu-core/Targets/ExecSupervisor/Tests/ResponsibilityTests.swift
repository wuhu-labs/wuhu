#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(macOS)
  import Darwin
#endif
import CExecSupervisor
@testable import ExecSupervisor
import Testing

@Suite struct ResponsibilityTests {
  @Test func supportedBoxAgentPolicyHasNoWarning() {
    var warnings = 0
    let disclaim = boxAgentDisclaimsResponsibility(available: true, reportUnavailable: { warnings += 1 })
    #if os(macOS)
      #expect(disclaim)
    #else
      #expect(!disclaim)
    #endif
    #expect(warnings == 0)
  }

  @Test func unavailableDisclaimCapabilityStillRunsExec() async throws {
    var warnings = 0
    let disclaim = boxAgentDisclaimsResponsibility(available: false, reportUnavailable: { warnings += 1 })
    #expect(!disclaim)
    #if os(macOS)
      #expect(warnings == 1)
    #else
      #expect(warnings == 0)
    #endif
    try await withExec(disclaimResponsibility: disclaim) { agent in
      let id = UUID()
      try await startExec(agent, id: id, script: "printf fallback-ok")
      let output = try await waitOutputEnd(agent, id: id)
      #expect(output.payload?.data == Data("fallback-ok".utf8))
    }
  }

  #if os(macOS)
    @Test(arguments: [false, true]) func disclaimerSetterIsOnlyAppliedToBoxPolicy(disclaim: Bool) throws {
      var child = exec_child()
      let error = withCStringArray(["/usr/bin/true"]) { argv in
        withCStringArray([]) { environment in
          exec_spawn_with_disclaimer(argv, environment, "/tmp", disclaim ? 1 : 0, { attributes, value in
            attributes != nil && value == 1 ? EPERM : EINVAL
          }, &child)
        }
      }
      if disclaim {
        #expect(error == EPERM)
        #expect(child.pid == 0)
      } else {
        try #require(error == 0)
        _ = exec_reap(child.pid)
        exec_close(child.input); exec_close(child.output); exec_close(child.error)
      }
    }

    @Test func absentSetterFallsBackToNormalSpawn() throws {
      var child = exec_child()
      let error = withCStringArray(["/usr/bin/true"]) { argv in
        withCStringArray([]) { environment in
          exec_spawn_with_disclaimer(argv, environment, "/tmp", 1, nil, &child)
        }
      }
      try #require(error == 0)
      _ = exec_reap(child.pid)
      exec_close(child.input); exec_close(child.output); exec_close(child.error)
    }

    @Test(.enabled(if: exec_disclaim_responsibility_available() != 0), arguments: [false, true]) func nativeChildResponsibility(disclaim: Bool) async throws {
      let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"))
      let responsible = unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Int32).self)
      let parent = responsible(getpid())
      #expect(parent > 0)
      #expect(exec_disclaim_responsibility_available() != 0)
      var child = exec_child()
      let error = withCStringArray(["/bin/sleep", "100"]) { argv in
        withCStringArray([]) { environment in
          exec_spawn(argv, environment, "/tmp", disclaim ? 1 : 0, &child)
        }
      }
      try #require(error == 0)
      defer {
        _ = exec_signal_group(child.pid, SIGKILL)
        _ = exec_reap(child.pid)
        exec_close(child.input); exec_close(child.output); exec_close(child.error)
      }
      let actual = responsible(child.pid)
      #expect(actual > 0)
      if disclaim {
        #expect(actual == child.pid)
        #expect(actual != parent)
      }
    }

    // The live Desktop EPERM proof is recorded on the issue; it completed without a consent wait.
    // CI cannot promise an ungranted Desktop and could hang on consent.
    @Test(.disabled("Live TCC proof requires an existing, ungranted Desktop on the pool host"))
    func disclaimedDesktopProbe() async throws {
      #expect(exec_disclaim_responsibility_available() != 0)
      let script = """
      exec /usr/bin/python3 -c 'import errno,os,pwd; p=pwd.getpwuid(os.getuid()).pw_dir+"/Desktop"; print("tcc-probe",p,flush=True)
      try:
       os.listdir(p)
      except OSError as e:
       print("errno",e.errno,flush=True); raise SystemExit(0 if e.errno==errno.EPERM else 2)
      print("access-allowed",flush=True); raise SystemExit(3)'
      """
      try await withExec(disclaimResponsibility: true) { agent in
        let id = UUID()
        try await startExec(agent, id: id, script: script)
        let output = try await waitOutputEnd(agent, id: id)
        let text = String(decoding: output.payload?.data ?? Data(), as: UTF8.self)
        print(text)
        #expect(text.contains("errno 1"), "A live EPERM proof needs an existing Desktop without pre-granted access; allowed/missing paths are inconclusive")
      }
    }
  #endif
}
