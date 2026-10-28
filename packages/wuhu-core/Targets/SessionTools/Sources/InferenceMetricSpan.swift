import struct InferenceKit.InferenceMetric
import ServerTelemetry

extension TelemetrySpan<ModelAttemptOutcome> {
  /// One `model.attempt`'s outcome, read off the metric the attempt reports.
  public func record(_ metric: InferenceMetric) {
    set(.provider, metric.provider)
    set(.requestModel, metric.model)
    set(.responseModel, metric.servedModel)
    set(.effort, metric.effort)
    set(.inferenceID, metric.id)
    set(.ttftMs, metric.ttftMs.map(Int.init))
    set(.httpStatus, metric.status)
    set(.errorType, metric.failure)
    if let usage = metric.usage {
      set(.inputTokens, usage.inputTokens)
      set(.outputTokens, usage.outputTokens)
      set(.cacheReadTokens, usage.cacheReadTokens)
      set(.cacheCreationTokens, usage.cacheWriteTokens)
      set(.reasoningTokens, usage.reasoningTokens)
    }
    conclude(metric.outcome == .ok ? .ok : metric.outcome == .cancelled ? .cancelled : .errored, providerText: metric.errorText)
  }
}
