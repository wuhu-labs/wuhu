import CLIKit
import Testing

@Suite struct CapturedProcessOutputTests {
  @Test func everyShortOutputArrivesWhole() async throws {
    let mismatches = try await withThrowingTaskGroup(of: Int.self) { group in
      for index in 0 ..< 400 {
        if index >= 16 { _ = try await group.next() }
        group.addTask { try await capturedProcessOutput(["/bin/sh", "-c", "printf '%s\\n' \"$0\"", "user\(index)"]) == "user\(index)\n" ? 0 : 1 }
      }
      return try await group.reduce(0, +)
    }
    #expect(mismatches == 0)
  }

  @Test func largeOutputIsComplete() async throws {
    let output = try await capturedProcessOutput(["/bin/sh", "-c", "head -c 18874368 /dev/zero | tr '\\000' a"])
    #expect(output.utf8.count == 18 << 20)
    #expect(output.utf8.allSatisfy { $0 == UInt8(ascii: "a") })
  }

  @Test func aFailureCarriesItsStatusAndStandardError() async throws {
    let command = ["/bin/sh", "-c", "echo partial; echo ' broken ' >&2; exit 3"]
    let failure = await #expect(throws: CommandFailure.self) { try await capturedProcessOutput(command) }
    #expect(failure?.command == command)
    #expect(failure?.status == 3)
    #expect(failure?.stderr == "broken")
  }

  @Test func aFailureCarriesLargeStandardErrorWhole() async throws {
    let failure = await #expect(throws: CommandFailure.self) { try await capturedProcessOutput(["/bin/sh", "-c", "head -c 2097152 /dev/zero | tr '\\000' e >&2; exit 4"]) }
    #expect(failure?.status == 4)
    #expect(failure?.stderr.utf8.count == 2 << 20)
  }
}
