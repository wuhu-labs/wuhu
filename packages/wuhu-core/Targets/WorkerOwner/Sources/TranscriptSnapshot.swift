import struct SessionDomain.SubscriptionID
import struct SessionDomain.Transcript
import enum SessionDomain.TranscriptItem

struct TranscriptSnapshot: Codable, Sendable {
  let items: [TranscriptItem]
  let keptCount: Int
  let registeredSubscriptions: Set<SubscriptionID>?
  let handlerSubscriptions: Set<SubscriptionID>
  init(_ transcript: Transcript) {
    items = transcript.items; keptCount = transcript.keptCount; registeredSubscriptions = transcript.registeredSubscriptions; handlerSubscriptions = transcript.handlerSubscriptions
  }

  var value: Transcript {
    .init(items: items, keptCount: keptCount, registeredSubscriptions: registeredSubscriptions, handlerSubscriptions: handlerSubscriptions)
  }
}
