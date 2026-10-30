#if os(macOS) || os(Linux)
  import Foundation
  import XCTest

  /// Makes `ExitTestHarnessTests`' empty exit test fail if the runner runs XCTest cases in an exit-test child.
  final class ExitTestChildXCTests: XCTestCase {
    func testDoesNotRunInAnExitTestChild() {
      if ProcessInfo.processInfo.environment["SWT_EXIT_TEST_ID"] != nil { exit(3) }
    }
  }
#endif
