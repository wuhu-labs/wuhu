import Foundation

struct WuhuToolExecutionError: Error, Sendable, CustomStringConvertible, Hashable {
  var message: String

  var description: String {
    message
  }
}
