import Foundation

public enum AgentError: Error, Sendable, CustomStringConvertible, Equatable {
  case alreadyProcessingPrompt
  case alreadyProcessingContinue
  case invalidContinue(String)

  public var description: String {
    switch self {
    case .alreadyProcessingPrompt:
      "Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion."
    case .alreadyProcessingContinue:
      "Agent is already processing. Wait for completion before continuing."
    case let .invalidContinue(message):
      message
    }
  }
}
