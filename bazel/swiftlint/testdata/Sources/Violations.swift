@testable import Foundation

func sign(_ value: Int) -> Int {
  if value > 0 {
    1
  } else if value > 0 {
    -1
  } else {
    0
  }
}

import Combine

let lock = NSLock()
let json = JSONSerialization.self
func delay() async throws { try await Task.sleep(for: .seconds(1)) }
class UnsafeValue: @unchecked Sendable {}
class Model: ObservableObject {
  @Published var value = 0
}

struct View {
  @ObservedObject var model: Model
}

// swiftlint:disable:next no_nslock - deliberately orphaned exception
let value = 1
