import Foundation
import struct SpaceContract.PixelSize
import WuhuAI

public struct ContextBudget: Hashable, Sendable {
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

func estimateTokens(_ text: String) -> Int {
  Int((Double(text.utf8.count) / 4.0).rounded(.up))
}

extension Transcript {
  // Usage totals report context size at inference time. Carried items
  // (index < keptCount) were inferred against the pre-compaction context, so
  // trusting their usage would re-trigger compaction off its own kept tail
  // forever. Trust only the last fresh usage; estimate everything after it.
  public func estimatedContextTokens(images: ImageLimits) -> Int {
    var lastKnownTokens = 0
    var lastUsageIndex = keptCount - 1
    for index in keptCount ..< items.count {
      guard case let .assistant(entry) = items[index] else { continue }
      lastKnownTokens = entry.usage.totalTokens
      lastUsageIndex = index
    }
    let estimated = items[(lastUsageIndex + 1)...]
      .map { $0.estimatedTokens(images) }
      .reduce(0, +)
    return lastKnownTokens + estimated
  }

  public func contextFullness(budget: ContextBudget) -> Double {
    Double(estimatedContextTokens(images: budget.images)) / Double(budget.usableTokens)
  }
}

extension TranscriptItem {
  // Bytes say nothing about an image's token cost; its pixel size, as the
  // model will receive it, does.
  func estimatedTokens(_ images: ImageLimits) -> Int {
    switch self {
    case let .assistant(entry):
      entry.content.map { $0.estimatedTokens(images) }.reduce(0, +)
    default:
      estimateTokens(estimationText) + imageSizes.map(images.tokens).reduce(0, +)
    }
  }

  var imageSizes: [PixelSize?] {
    switch self {
    case let .toolResult(result): result.payload.imageSizes
    case let .direct(message): message.content.modelImages.map(\.pixels)
    case let .message(message): message.content.modelImages.map(\.pixels)
    case let .notification(notification): notification.content.modelImages.map(\.pixels)
    default: []
    }
  }

  var estimationText: String {
    switch self {
    case let .direct(message):
      message.header.render() + "\n\n" + message.content.renderedText
    case let .message(message):
      message.header.render() + "\n\n" + message.content.renderedText
    case let .notification(notification):
      notification.header.render() + "\n\n" + notification.content.renderedText
    case let .assistant(entry):
      entry.content.map(\.estimationText).joined(separator: "\n")
    case let .toolResult(result):
      result.payload.renderedText
    case let .bookmark(marker):
      marker.name ?? "bookmark"
    case let .generationHead(head):
      head.snapshot.rendered + "\n" + head.summary + "\n" + (head.note ?? "")
    }
  }
}

extension ContentBlock {
  func estimatedTokens(_ images: ImageLimits) -> Int {
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
  var imageSizes: [PixelSize?] {
    guard case let .read(result) = self, let image = result.image else { return [] }
    return [image.pixels]
  }

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
