#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import JSONValue
import OrderedCollections

extension CapabilityClient {
  public func image(_ prompt: String, images: [Data] = [], options: CapabilityOptions = .init()) async throws -> Data {
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, images.count <= 5,
          images.allSatisfy({ !$0.isEmpty && $0.count <= 25 * 1024 * 1024 })
    else {
      throw CapabilityError(.invalidArgument, "Images need a nonempty prompt and at most five references of at most 25 MiB each.")
    }
    let provider = try await resolve(.image, options: options)
    if !images.isEmpty, provider.facts.edit != true {
      throw CapabilityError(.unsupportedFeature, "Model '\(provider.model)' cannot edit images.", hint: "Choose an editing model such as qwen-image-3.0, qwen-image-edit-plus or gpt-image-2; draft is generation-only.")
    }
    let size = options.size ?? "1024x1024"
    guard ["1024x1024", "1536x1024", "1024x1536"].contains(size) else {
      throw CapabilityError(.invalidArgument, "Size must be 1024x1024, 1536x1024 or 1024x1536.")
    }
    let quality: String
    switch options.quality ?? "standard" {
    case "draft": quality = "low"
    case "standard": quality = "medium"
    case "fine": quality = "high"
    case "ultra":
      guard provider.dialect == "dashscope" else {
        throw CapabilityError(.unsupportedFeature, "The selected image model has no distinct ultra tier.", hint: "Use fine, or select Qwen's wan2.7-image-pro ultra tier explicitly.")
      }
      quality = "high"
    default: throw CapabilityError(.invalidArgument, "Quality must be draft, standard, fine or ultra.")
    }
    if provider.dialect == "dashscope", images.contains(where: { $0.count > 10 * 1024 * 1024 }) {
      throw CapabilityError(.invalidArgument, "DashScope reference images must be at most 10 MiB each.")
    }
    if provider.dialect == "dashscope", ["qwen-image-3.0", "qwen-image-3.0-pro", "qwen-image-edit-plus", "qwen-image-edit-max"].contains(provider.model), images.count > 3 {
      throw CapabilityError(.invalidArgument, "This Qwen image model accepts at most three references.")
    }
    let imageURLs = images.map { "data:image/png;base64,\($0.base64EncodedString())" }
    let payload: JSONValue
    if provider.dialect == "dashscope" {
      let content: [JSONValue] = imageURLs.map { .object(["image": .string($0)]) } + [.object(["text": .string(prompt)])]
      payload = try await post(provider, "services/aigc/multimodal-generation/generation", .object([
        "model": .string(provider.model),
        "input": .object(["messages": .array([.object(["role": .string("user"), "content": .array(content)])])]),
        "parameters": .object(["size": .string(size.replacingOccurrences(of: "x", with: "*")), "prompt_extend": .bool(false)]),
      ]))
      guard let url = payload["output"]["choices"].list.first?["message"]["content"].list.compactMap({ $0["image"].text }).first else {
        throw CapabilityError(.providerUnavailable, "DashScope returned no image.")
      }
      return try await download(url)
    }
    if images.isEmpty || provider.dialect == "codex" {
      var body: OrderedDictionary<String, JSONValue> = ["prompt": .string(prompt), "model": .string(provider.model), "n": .integer(1), "size": .string(size)]
      if options.quality != nil { body["quality"] = .string(quality) }
      if !images.isEmpty { body["images"] = .array(imageURLs.map { .object(["image_url": .string($0)]) }) }
      payload = try await post(provider, images.isEmpty ? "images/generations" : "images/edits", .object(body))
    } else {
      var form = MultipartForm(boundary: TranscriberTransport.boundary())
      form.appendField("model", provider.model)
      form.appendField("prompt", prompt)
      form.appendField("n", "1")
      form.appendField("size", size)
      if options.quality != nil { form.appendField("quality", quality) }
      for (index, image) in images.enumerated() {
        form.appendFile(name: "image[]", filename: "reference-\(index).png", contentType: "image/png", bytes: image)
      }
      let body = form.finish()
      var headers = provider.headers
      headers.set("content-type", body.contentType)
      payload = try await json(Request(url: provider.baseURL.appendingPathComponent("images/edits"), method: .post, headers: headers, body: body))
    }
    guard let encoded = payload["data"].list.first?["b64_json"].text, let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else {
      throw CapabilityError(.providerUnavailable, "The capability provider returned no decodable image.")
    }
    return bytes
  }
}
