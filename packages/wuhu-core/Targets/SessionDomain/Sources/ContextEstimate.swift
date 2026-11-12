import Foundation
import WuhuAI

public struct ContextBudget: Hashable, Sendable, Codable {
  public var maxInput: Int
  public var maxOutput: Int
  public var headroomOverride: Int?
  public var images: ImageLimits

  public init(maxInput: Int, maxOutput: Int, headroomOverride: Int? = nil, images: ImageLimits = .claude) {
    self.maxInput = maxInput
    self.maxOutput = maxOutput
    self.headroomOverride = headroomOverride
    self.images = images
  }

  public var usableTokens: Int {
    maxInput - (headroomOverride ?? maxOutput)
  }
}

public struct CompactionThresholds: Hashable, Sendable {
  public var soft: Double
  public var hard: Double

  public init(soft: Double = 0.7, hard: Double = 0.85) {
    self.soft = soft
    self.hard = hard
  }
}

public func estimateTokens(_ text: String) -> Int {
  Int((Double(text.utf8.count) / 4.0).rounded(.up))
}

extension [TranscriptLine] {
  /// Usage totals report the context at inference time, and only a reply made in this generation has one (`TranscriptLine.Meta`): the last is trusted, everything after it estimated.
  public func estimatedContextTokens(images: ImageLimits) -> Int {
    let last = lastIndex { $0.meta != nil }
    let known = last.map { self[$0].meta!.usage.totalTokens } ?? 0
    return self[(last.map { $0 + 1 } ?? 0)...].reduce(known) { $0 + $1.message.estimatedTokens(images) }
  }

  public func contextFullness(budget: ContextBudget) -> Double {
    Double(estimatedContextTokens(images: budget.images)) / Double(budget.usableTokens)
  }
}

extension Message {
  public func estimatedTokens(_ images: ImageLimits) -> Int {
    let content = switch self {
    case let .user(message): message.content
    case let .assistant(message): message.content
    case let .toolResult(message): message.content
    }
    return content.reduce(0) { $0 + $1.estimatedTokens(images) }
  }
}

extension ContentBlock {
  public func estimatedTokens(_ images: ImageLimits) -> Int {
    switch self {
    case .media:
      images.tokens(nil)
    case .text, .reasoning, .toolCall, .hostedTool:
      estimateTokens(estimationText)
    }
  }

  var estimationText: String {
    switch self {
    case let .text(text):
      text.text
    case let .reasoning(reasoning):
      switch reasoning {
      case let .unencrypted(text): text
      case let .encrypted(content): content.summary ?? content.opaque
      }
    case let .toolCall(call):
      "\(call.name) \(call.arguments)"
    case let .hostedTool(item):
      item.digest
    case let .media(media):
      media.url.absoluteString
    }
  }
}

extension ToolResultPayload {
  var isFailure: Bool {
    switch self {
    case .failure: true
    default: false
    }
  }

  public var renderedText: String {
    switch self {
    case let .read(result):
      result.content
    case let .write(result):
      "wrote \(result.path)"
    case let .edit(result):
      "edited \(result.path)"
    case let .grep(result):
      result.output
    case let .find(result):
      result.output
    case let .exec(result):
      (result.reaped ? "[process reaped after caller absence; output buffered to termination]\n" : "")
        + (result.exitCode == 0 ? result.output : result.output + "\n(exit code \(result.exitCode))")
    case let .mount(result):
      result.contextEmission ?? "mounted \(result.mount.location)"
    case let .machines(result):
      result.rendered
    case let .templates(result):
      result.rendered
    case let .observe(result):
      "observing (subscription \(result.subscriptionID.rawValue))"
    case let .timer(result):
      "timer registered (subscription \(result.subscriptionID.rawValue))"
    case let .cancelObservation(result):
      "cancelled observation \(result.subscriptionID.rawValue)"
    case let .cancelTimer(result):
      "cancelled timer \(result.subscriptionID.rawValue)"
    case let .query(result):
      result.output
    case let .script(result):
      result.output
    case let .text(result):
      result.output
    case let .sendMessage(result):
      "posted \(result.messageID.rawValue) to conversation \(result.conversationID.rawValue)"
    case let .request(result):
      "opened request \(result.requestID.rawValue) on \(result.task.rawValue)"
    case let .report(result):
      "reported \(result.kind.rawValue) on request \(result.requestID.rawValue)"
    case let .createSession(result):
      "created session \(result.sessionID.rawValue) (\(result.title))"
    case let .setTitle(result):
      "title is now \(result.title)"
    case let .manipulateUI(result):
      "sent command \(result.n) to device \(result.device)"
    case let .compact(result):
      result.summary
    case let .failure(failure):
      failure.message
    }
  }
}
