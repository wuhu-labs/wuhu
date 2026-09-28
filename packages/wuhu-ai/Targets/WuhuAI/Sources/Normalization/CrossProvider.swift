import Foundation

// MARK: - Tool Call ID Normalization

/// Rewrite every tool call ID in a message list into a provider-safe wire form.
///
/// This is pure and context-free: each ID maps through ``wireToolCallID(_:)``
/// independently, so an assistant `tool_use`/`tool_call` and its matching
/// `tool_result` always agree without any shared map or per-request state. Apply
/// it on every outbound request, for every dialect — valid IDs pass through
/// untouched, so it is a no-op in the common case.
func normalizeToolCallIDs(in messages: inout [Message]) {
  for i in messages.indices {
    switch messages[i] {
    case var .assistant(msg):
      var changed = false
      for j in msg.content.indices {
        if case var .toolCall(tc) = msg.content[j] {
          let wire = wireToolCallID(tc.id)
          if wire != tc.id {
            tc.id = wire
            msg.content[j] = .toolCall(tc)
            changed = true
          }
        }
      }
      if changed {
        messages[i] = .assistant(msg)
      }

    case var .toolResult(msg):
      let wire = wireToolCallID(msg.toolCallId)
      if wire != msg.toolCallId {
        msg.toolCallId = wire
        messages[i] = .toolResult(msg)
      }

    default:
      break
    }
  }
}

/// Map a single tool call ID into a universally valid wire form.
///
/// Tool-call ID constraints are undocumented and vary per provider, so this
/// targets the strictest *verified* subset: ASCII `[a-zA-Z0-9_-]`, length ≤ 64
/// (Anthropic's documented `tool_use.id` charset; also the empirically observed
/// OpenAI Responses `call_id` cap). An ID already inside that subset is returned
/// unchanged — preserving provider-native IDs and, with them, prompt-cache
/// prefixes. Anything outside it (a foreign charset, an over-long ID, or a
/// legacy compound `call_id|item_id`) is replaced with a deterministic
/// `wuhu_<hash>`.
///
/// Because the mapping is a pure function of the single ID — no dependence on
/// other tool calls in the request — the same input always yields the same
/// output. That keeps cache prefixes stable across turns and guarantees a tool
/// call and its result rewrite identically without bookkeeping. It is also
/// idempotent: a `wuhu_…` result is itself valid and passes back through
/// unchanged.
func wireToolCallID(_ id: String) -> String {
  if isValidWireToolCallID(id) { return id }
  return "wuhu_" + stableToolIDHash(id)
}

private let maxWireToolCallIDLength = 64

private func isValidWireToolCallID(_ id: String) -> Bool {
  guard !id.isEmpty, id.utf8.count <= maxWireToolCallIDLength else { return false }
  for scalar in id.unicodeScalars {
    switch scalar.value {
    case 48 ... 57, 65 ... 90, 97 ... 122, 45, 95: continue // 0-9 A-Z a-z - _
    default: return false
    }
  }
  return true
}

/// A stable 128-bit hash of a string, hex-encoded (32 chars).
///
/// Two FNV-1a passes over the UTF-8 bytes with different offset bases give 128
/// bits without needing wide-integer arithmetic. This is intentionally *not*
/// cryptographic: tool IDs are not adversarial, and we only need distinct inputs
/// to stay distinct within a conversation. `wuhu_` + 32 hex = 37 chars, well
/// under the 64-char limit.
private func stableToolIDHash(_ value: String) -> String {
  func fnv1a(_ bytes: String.UTF8View, offsetBasis: UInt64) -> UInt64 {
    var hash = offsetBasis
    for byte in bytes {
      hash ^= UInt64(byte)
      hash &*= 0x0000_0100_0000_01B3 // FNV prime
    }
    return hash
  }
  func hex16(_ value: UInt64) -> String {
    let raw = String(value, radix: 16)
    return String(repeating: "0", count: 16 - raw.count) + raw
  }
  let lo = fnv1a(value.utf8, offsetBasis: 0xCBF2_9CE4_8422_2325)
  let hi = fnv1a(value.utf8, offsetBasis: 0x8422_2325_CBF2_9CE4)
  return hex16(hi) + hex16(lo)
}

// MARK: - Reasoning Normalization

/// Strip cross-provider reasoning to plain text on every outbound request.
///
/// An encrypted reasoning block carries the `providerID` that produced it, and
/// its opaque blob is provider-specific — an OpenAI Fernet token, an Anthropic
/// thinking signature, etc. Replayed to a *different* provider that blob is
/// meaningless and gets rejected: Anthropic returns
/// "Invalid `signature` in `thinking` block" when handed a foreign opaque.
///
/// Gated per block by the block's own `providerID` — the live transcript is
/// mixed-origin (e.g. GPT web-search turns followed by Anthropic turns in one
/// request), so a single conversation-level source provider would be wrong:
/// - same provider  → keep the opaque (faithful replay, prompt-cache friendly);
/// - other provider → fall back to the summary as plain text, drop the opaque;
/// - unencrypted reasoning carries no signature and is left untouched.
///
/// Applied unconditionally at the request-build choke point, like
/// ``normalizeToolCallIDs(in:)`` — same-provider replay is a no-op.
func normalizeReasoningForTarget(in messages: inout [Message], targetProviderID: String) {
  for i in messages.indices {
    guard case var .assistant(msg) = messages[i] else { continue }

    var changed = false
    var newContent: [ContentBlock] = []
    for block in msg.content {
      guard case let .reasoning(.encrypted(enc)) = block else {
        newContent.append(block)
        continue
      }
      if enc.providerID == targetProviderID {
        newContent.append(block) // same provider → faithful replay
      } else {
        changed = true
        if let summary = enc.summary,
           !summary[...].trimmedWhitespace.isEmpty
        {
          newContent.append(.text(TextContent(text: summary)))
        }
        // No summary → drop: the opaque is unusable by another provider.
      }
    }

    if changed {
      msg.content = newContent
      messages[i] = .assistant(msg)
    }
  }
}

func normalizeHostedToolsForTarget(in messages: inout [Message], targetProviderID: String) {
  for i in messages.indices {
    guard case var .assistant(message) = messages[i] else { continue }
    var changed = false
    message.content = message.content.map { block in
      guard case let .hostedTool(item) = block, item.providerID != targetProviderID else { return block }
      changed = true
      return .text(TextContent(text: item.digest))
    }
    if changed { messages[i] = .assistant(message) }
  }
}
