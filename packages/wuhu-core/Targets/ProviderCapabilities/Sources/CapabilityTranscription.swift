#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Clocks
import Dependencies
import Fetch
import JSONValue
import OrderedCollections

extension CapabilityClient {
  public func transcriberInfo(options: CapabilityOptions = .init()) async throws -> (provider: String, model: String) {
    let resolved = try await resolve(.transcription, options: options)
    return (resolved.provider, resolved.model)
  }

  public func transcribe(_ clip: AudioClip, options: CapabilityOptions = .init()) async throws -> Transcription {
    guard !clip.bytes.isEmpty, clip.bytes.count <= TranscriptionLimits.maximumBytes else {
      throw CapabilityError(.invalidArgument, "Audio must be nonempty and at most 25 MiB.")
    }
    guard let duration = AudioDuration.seconds(clip), duration.isFinite, duration >= 0 else {
      throw CapabilityError(.invalidArgument, "Audio duration cannot be established from this container.", hint: "Re-encode to WAV, MP3, M4A/MP4 or WebM with readable timing; MP4 fragments require track timescales, decode times and sample durations.")
    }
    guard duration <= 7200 else { throw CapabilityError(.invalidArgument, "Audio must be at most two hours.") }
    let provider = try await resolve(.transcription, options: options)
    let requested = options.timestamps ?? []
    guard requested.allSatisfy({ ["words", "segments"].contains($0) }) else {
      throw CapabilityError(.invalidArgument, "Timestamps must contain words and/or segments.")
    }
    if requested.contains(where: { !(provider.facts.timestamps ?? []).contains($0) }) || (options.diarize == true && provider.facts.diarize != true) {
      throw CapabilityError(.unsupportedFeature, "Model '\(provider.model)' does not support the requested transcription metadata.", hint: "qwen-audio-3.1-asr-flash-filetrans supports words, segments and diarization; whisper-1 supports timestamps without diarization.")
    }
    let result: Transcription
    switch provider.dialect {
    case "codex":
      var form = audioForm(clip)
      if let language = options.language { form.appendField("language", language) }
      let root = provider.baseURL.lastPathComponent == "codex" ? provider.baseURL.deletingLastPathComponent() : provider.baseURL
      let payload = try await multipart(provider, url: root.appendingPathComponent("transcribe"), form: form)
      guard let text = payload["text"].text else { throw missingTranscript() }
      result = .init(text: text, provider: provider.provider, model: provider.model)
    case "dashscope": result = try await qwenTranscribe(clip, provider: provider, options: options)
    default:
      var form = audioForm(clip)
      form.appendField("model", provider.model)
      let diarizationModel = provider.model == "gpt-4o-transcribe-diarize"
      let diarized = diarizationModel || options.diarize == true
      form.appendField("response_format", diarized ? "diarized_json" : requested.isEmpty ? "json" : "verbose_json")
      if !diarizationModel {
        for granularity in requested { form.appendField("timestamp_granularities[]", granularity == "words" ? "word" : "segment") }
      }
      if diarized { form.appendField("chunking_strategy", "auto") }
      if let language = options.language { form.appendField("language", language) }
      let payload = try await multipart(provider, url: provider.baseURL.appendingPathComponent("audio/transcriptions"), form: form)
      guard let text = payload["text"].text else { throw missingTranscript() }
      result = .init(
        text: text, provider: provider.provider, model: provider.model,
        language: payload["language"].text ?? payload["languages"].list.first?["code"].text,
        durationSeconds: payload["duration"].numeric ?? payload["usage"]["seconds"].numeric,
        segments: spans(payload["segments"], word: false), words: spans(payload["words"], word: true),
        confidence: payload["confidence"].numeric, usage: payload["usage"] == .null ? nil : payload["usage"],
      )
    }
    if let duration = result.durationSeconds, duration > 7200 { throw CapabilityError(.invalidArgument, "Audio exceeds two hours.") }
    func timed(_ spans: [TranscriptionSpan]?) -> Bool {
      guard let spans, !spans.isEmpty else { return false }
      return spans.allSatisfy { span in
        guard let start = span.start, let end = span.end else { return false }
        return start.isFinite && end.isFinite && start >= 0 && end >= start
      }
    }
    if requested.contains("words"), !timed(result.words) { throw CapabilityError(.providerUnavailable, "The provider omitted requested word timestamps.") }
    if requested.contains("segments"), !timed(result.segments) { throw CapabilityError(.providerUnavailable, "The provider omitted requested segment timestamps.") }
    if options.diarize == true, result.segments?.contains(where: { $0.speaker != nil }) != true { throw CapabilityError(.providerUnavailable, "The provider omitted requested speaker labels.") }
    return result
  }

  func audioForm(_ clip: AudioClip) -> MultipartForm {
    var form = MultipartForm(boundary: TranscriberTransport.boundary())
    form.appendFile(name: "file", filename: "audio.\(clip.mediaType.fileExtension)", contentType: clip.mediaType.rawValue, bytes: clip.bytes)
    return form
  }

  func multipart(_ provider: Resolved, url: URL, form: MultipartForm) async throws -> JSONValue {
    let body = form.finish()
    var headers = provider.headers
    headers.set("content-type", body.contentType)
    return try await json(Request(url: url, method: .post, headers: headers, body: body))
  }

  func missingTranscript() -> CapabilityError { .init(.providerUnavailable, "The provider returned no transcript text.") }

  func spans(_ value: JSONValue, word: Bool) -> [TranscriptionSpan]? {
    guard value != .null else { return nil }
    return value.list.compactMap { item in
      guard let text = item[word ? "word" : "text"].text else { return nil }
      return .init(text: text, start: item["start"].numeric, end: item["end"].numeric, speaker: item["speaker"].text, confidence: item["confidence"].numeric)
    }
  }

  private func qwenTranscribe(_ clip: AudioClip, provider: Resolved, options: CapabilityOptions) async throws -> Transcription {
    var form = audioForm(clip)
    form.appendField("model", provider.model)
    let uploaded = try await multipart(provider, url: provider.baseURL.appendingPathComponent("files"), form: form)
    guard let fileID = uploaded["data"]["uploaded_files"].list.first?["file_id"].text, !fileID.isEmpty,
          !fileID.contains("/"), fileID != ".", fileID != ".."
    else {
      throw CapabilityError(.providerUnavailable, "DashScope returned no managed file ID.")
    }
    let fileURL = provider.baseURL.appendingPathComponent("files").appendingPathComponent(fileID)
    do {
      let result = try await qwenUploaded(fileURL, provider: provider, options: options)
      _ = try? await send(Request(url: fileURL, method: .delete, headers: provider.headers))
      return result
    } catch {
      _ = try? await send(Request(url: fileURL, method: .delete, headers: provider.headers))
      throw error
    }
  }

  private func qwenUploaded(_ fileURL: URL, provider: Resolved, options: CapabilityOptions) async throws -> Transcription {
    let details = try await json(Request(url: fileURL, headers: provider.headers))
    guard let signed = details["data"]["url"].text else { throw missingTranscript() }
    var parameters: OrderedDictionary<String, JSONValue> = [:]
    if let language = options.language { parameters["language_hints"] = .array([.string(language)]) }
    if options.diarize == true { parameters["diarization_enabled"] = .bool(true) }
    if provider.model == "qwen3-asr-flash-filetrans", options.timestamps?.contains("words") == true { parameters["enable_words"] = .bool(true) }
    let submitted = try await post(provider, "services/audio/asr/transcription", .object([
      "model": .string(provider.model), "input": .object(["file_urls": .array([.string(signed)])]), "parameters": .object(parameters),
    ]), asynchronous: true)
    guard let taskID = submitted["output"]["task_id"].text, !taskID.isEmpty, !taskID.contains("/"), taskID != ".", taskID != ".." else { throw missingTranscript() }
    @Dependency(\.continuousClock) var continuousClock
    let clock = AnyClock(continuousClock)
    let deadline = clock.now.advanced(by: .seconds(600))
    var output = submitted["output"]
    var usage = submitted["usage"]
    while ["PENDING", "RUNNING"].contains(output["task_status"].text ?? "PENDING") {
      guard clock.now < deadline else { throw CapabilityError(.providerUnavailable, "DashScope transcription exceeded its ten-minute deadline.") }
      try await clock.sleep(for: .seconds(1))
      let polled = try await json(Request(url: provider.baseURL.appendingPathComponent("tasks").appendingPathComponent(taskID), headers: provider.headers))
      output = polled["output"]
      if polled["usage"] != .null { usage = polled["usage"] }
    }
    guard output["task_status"].text == "SUCCEEDED", let subtask = output["results"].list.first,
          subtask["subtask_status"].text == "SUCCEEDED", let url = subtask["transcription_url"].text
    else {
      throw CapabilityError(.providerUnavailable, "DashScope transcription task failed.")
    }
    let bytes = try await download(url)
    guard let payload = JSONValue.parse(String(decoding: bytes, as: UTF8.self)), !payload["transcripts"].list.isEmpty else { throw missingTranscript() }
    let transcripts = payload["transcripts"].list
    let texts = transcripts.compactMap { $0["text"].text }
    guard texts.count == transcripts.count else { throw missingTranscript() }
    let sentences = transcripts.flatMap { $0["sentences"].list }
    func span(_ item: JSONValue, speaker: String? = nil) -> TranscriptionSpan? {
      guard let text = item["text"].text else { return nil }
      let label = item["speaker_id"].speakerLabel ?? speaker
      return .init(text: text, start: item["begin_time"].numeric.map { $0 / 1000 }, end: item["end_time"].numeric.map { $0 / 1000 }, speaker: label, confidence: item["confidence"].numeric)
    }
    let segments = sentences.compactMap { span($0) }
    let words = sentences.flatMap { sentence in
      let speaker = sentence["speaker_id"].speakerLabel
      return sentence["words"].list.compactMap { span($0, speaker: speaker) }
    }
    return .init(
      text: texts.joined(separator: "\n"),
      provider: provider.provider,
      model: provider.model,
      language: payload["properties"]["language"].text,
      durationSeconds: payload["properties"]["original_duration_in_milliseconds"].numeric.map { $0 / 1000 },
      segments: segments.isEmpty ? nil : segments,
      words: words.isEmpty ? nil : words,
      confidence: payload["confidence"].numeric,
      usage: payload["usage"] == .null ? (usage == .null ? nil : usage) : payload["usage"],
    )
  }
}
