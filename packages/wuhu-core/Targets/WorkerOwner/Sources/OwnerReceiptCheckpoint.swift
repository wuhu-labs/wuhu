#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError
import struct WorkerProtocol.WorkerReply

struct OwnerReceiptCheckpoint: Codable, Sendable {
  struct Entry: Codable, Sendable {
    let call: WorkerCall
    let reply: WorkerReply
  }

  struct Client: Codable, Sendable {
    let id: UUID
    let consumed: Int
    let acknowledged: Set<Int>
    let entries: [Entry]
  }

  let identity: UUID
  let clients: [Client]

  func restore() throws -> (clients: [UUID: OwnerReceiptJournal.Client], bytes: Int) {
    var restored: [UUID: OwnerReceiptJournal.Client] = [:]
    var bytes = 0
    var count = 0
    guard clients.count <= 16 else { throw invalid() }
    for client in clients {
      guard restored[client.id] == nil, client.consumed >= 0, client.acknowledged.count <= 1024,
            client.acknowledged.allSatisfy({ $0 > client.consumed && $0 - client.consumed <= 1024 }),
            client.consumed == Int.max || !client.acknowledged.contains(client.consumed + 1)
      else { throw invalid() }
      var entries: [Int: OwnerReceiptJournal.Entry] = [:]
      for entry in client.entries {
        let call = entry.call, reply = entry.reply
        guard let receipt = call.receipt, receipt.endpoint == identity, receipt.client == client.id,
              receipt.sequence > client.consumed, receipt.sequence - client.consumed <= 1024,
              !client.acknowledged.contains(receipt.sequence), entries[receipt.sequence] == nil,
              call.abi == 1, reply.abi == call.abi, reply.id == call.id, (reply.result != nil) != (reply.error != nil)
        else { throw invalid() }
        let inputBytes = call.payload.jsonString().utf8.count
        let replyBytes = try JSONEncoder().encode(reply).count
        count += 1
        guard count <= 1024, inputBytes <= 64 << 20, replyBytes <= 64 << 20,
              bytes + inputBytes + replyBytes <= 128 << 20
        else { throw invalid() }
        bytes += inputBytes + replyBytes
        entries[receipt.sequence] = .init(call: call, task: Task { reply }, reply: reply, bytes: inputBytes + replyBytes)
      }
      restored[client.id] = .init(consumed: client.consumed, acknowledged: client.acknowledged, entries: entries)
    }
    return (restored, bytes)
  }

  private func invalid() -> WorkerProtocolError { .init(.invalidConfiguration, message: "Invalid retained owner receipt checkpoint") }
}
