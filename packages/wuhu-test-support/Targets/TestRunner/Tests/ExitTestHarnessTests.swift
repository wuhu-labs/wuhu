#if os(macOS) || os(Linux)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #endif
  import Testing

  /// Canary for the generated Bazel test runner: `.failure` matches any crash, so a harness that kills the
  /// exit-test child before its body runs would make every `processExitsWith: .failure` pass vacuously.
  @Suite struct ExitTestHarnessTests {
    @Test func `an empty exit test exits successfully`() async {
      await #expect(processExitsWith: .success) {}
    }

    @Test func `an exit test exits with its body's status`() async {
      await #expect(processExitsWith: .exitCode(42)) { exit(42) }
    }
  }
#endif
