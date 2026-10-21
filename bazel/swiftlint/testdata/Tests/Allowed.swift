
import Combine

let lock = NSLock()
let json = JSONSerialization.self
func delay() async throws { try await Task.sleep(for: .seconds(1)) }
class UnsafeValue: @unchecked Sendable {}
class Model: ObservableObject { @Published var value = 0 }
