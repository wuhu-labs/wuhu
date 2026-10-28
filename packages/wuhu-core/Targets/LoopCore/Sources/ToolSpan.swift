import func MainHub.isRunningJSON
import struct OperationProtocol.OperationError
import ServerTelemetry
import SessionDomain
import enum SpaceContract.ErrorCode

extension TelemetrySpan<StepOutcome> {
  /// `payload` is what was written to the transcript, clamped; nil for a tool that writes none.
  func record(_ payload: ToolResultPayload?) {
    set(.bytesOut, payload?.renderedText.utf8.count ?? 0)
    switch payload {
    case let .failure(failure)?:
      if let code = failure.code.flatMap(ErrorCode.init(rawValue:)) {
        set(.errorType, code)
      } else if let code = failure.code.map(OperationError.Code.init(rawValue:)), code.isKnown {
        set(.errorType, code)
      }
      conclude(.errored)
      return
    case let .exec(result)?:
      set(.running, isRunningJSON(result.output))
    case let .script(result)?:
      set(.running, isRunningJSON(result.output))
    case let .request(result)?:
      set(.requestID, result.requestID)
      set(.childSession, result.task)
    case let .createSession(result)?:
      set(.requestID, result.requestID)
      set(.childSession, result.sessionID)
    case let .report(result)?:
      set(.requestID, result.requestID)
    default:
      break
    }
    conclude(.ok)
  }
}
