// NSLock JSONSerialization Task.sleep import Combine @unchecked Sendable ObservableObject @Published @ObservedObject
let text = "NSLock JSONSerialization Task.sleep import Combine @unchecked Sendable ObservableObject @Published @ObservedObject"
struct Value: Sendable {}
@Observable class Model {}
// swiftlint:disable:next no_nslock - audited legacy bridge
let lock = NSLock()
// swiftlint:disable:next no_jsonserialization - untyped tooling JSON
let json = JSONSerialization.self
// swiftlint:disable:next no_task_sleep - clock adapter
func delay() async throws { try await Task.sleep(for: .seconds(1)) }
// swiftlint:disable:next no_combine_import - framework bridge
import Combine

// swiftlint:disable:next no_unchecked_sendable - audited bridge
class UnsafeValue: @unchecked Sendable {}
// swiftlint:disable:next no_observable_object - framework bridge
class LegacyModel: ObservableObject {
  // swiftlint:disable:next no_observable_object - framework bridge
  @Published var value = 0
}

struct View {
  // swiftlint:disable:next no_observable_object - framework bridge
  @ObservedObject var model: LegacyModel
}

// swiftlint:disable:next no_observable_object - attributed framework bridge
class MainModel: @MainActor ObservableObject {}
// swiftlint:disable:next no_observable_object - attributed framework bridge
class ConcurrentModel: @preconcurrency ObservableObject {}
// swiftlint:disable:next no_observable_object - attributed framework bridge
extension ForeignModel: @retroactive Combine.ObservableObject {}
