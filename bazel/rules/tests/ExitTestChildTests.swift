#if os(macOS) || os(Linux)
  import Foundation
  import Testing
  import XCTest

  /// Makes the empty exit test below fail if the Bazel runner runs XCTest cases in an exit-test child.
  final class ExitTestChildXCTests: XCTestCase {
    func testDoesNotRunInAnExitTestChild() {
      if ProcessInfo.processInfo.environment["SWT_EXIT_TEST_ID"] != nil { exit(3) }
    }
  }

  @Suite struct ExitTestChildTests {
    @Test func `an empty exit test exits successfully`() async {
      await #expect(processExitsWith: .success) {}
    }
  }
#endif
