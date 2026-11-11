import struct ExecutionOwner.LineDifferenceLog
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import struct LoopCore.InferenceRequest
import struct LoopCore.TurnDifference
import struct SessionDomain.TranscriptPreamble
import struct SpaceCore.SessionStore
import struct SpaceCore.TranscriptLineDifference

// The one mismatch-check toggle: WUHU_TRANSCRIPT_DIFF_LOG names the JSONL file
// each request whose stored lines differ from the typed-item render appends to.
func lineDifferenceLog(environment: [String: String] = ProcessInfo.processInfo.environment) -> LineDifferenceLog? {
  guard let path = environment["WUHU_TRANSCRIPT_DIFF_LOG"], !path.isEmpty else { return nil }
  do {
    return try .file(URL(fileURLWithPath: path))
  } catch {
    Logger(label: "wuhu.lines").error("transcript diff log unavailable", metadata: ["path": "\(path)", "error": "\(error)"])
    return nil
  }
}

extension LineDifferenceLog {
  func record(_ difference: TurnDifference) async {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let line = try? encoder.encode(difference) else { return }
    await append(line + Data("\n".utf8))
  }
}

/// Never throws: a failed check is logged and the request goes on.
func checkLines(_ log: LineDifferenceLog, store: SessionStore, request: InferenceRequest, preamble: TranscriptPreamble, at time: Date) async {
  do {
    guard let difference = try await store.lineDifference(request.sessionID, generation: request.generation, preamble: preamble, transcript: request.transcript) else { return }
    let record = LineDifferenceRecord(
      time: time.formatted(.iso8601), session: request.sessionID.rawValue, generation: request.generation, position: difference.position,
      line: difference.line.map(LineDifferenceRecord.Side.init), render: difference.render.map(LineDifferenceRecord.Side.init),
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    await log.append(try encoder.encode(record) + Data("\n".utf8))
  } catch {
    Logger(label: "wuhu.lines").error("transcript line check failed", metadata: ["session": "\(request.sessionID.rawValue)", "error": "\(error)"])
  }
}

private struct LineDifferenceRecord: Encodable {
  struct Side: Encodable {
    var hash: String
    var excerpt: String

    init(_ side: TranscriptLineDifference.Side) {
      hash = side.hash
      excerpt = side.excerpt
    }
  }

  var time: String
  var session: String
  var generation: Int
  var position: Int
  var line: Side?
  var render: Side?
}
