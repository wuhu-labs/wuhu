#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import JSONValue

public struct WebSearchResult: Sendable, Codable, Equatable {
  public struct Source: Sendable, Codable, Equatable {
    public var title: String
    public var url: String
    public var snippet: String?
    public var published: String?
  }

  public var query: String
  public var provider: String
  public var sources: [Source]
  public var text: String?
}

extension CapabilityClient {
  public func search(_ query: String, options: CapabilityOptions = .init()) async throws -> WebSearchResult {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1 ... 20).contains(options.count ?? 8) else {
      throw CapabilityError(.invalidArgument, "Search needs a nonempty query and count between 1 and 20.")
    }
    let provider = try await resolve(.search, options: options)
    let count = options.count ?? 8
    let payload: JSONValue
    switch provider.dialect {
    case "brave":
      var url = URLComponents(url: provider.baseURL.appendingPathComponent("web/search"), resolvingAgainstBaseURL: false)!
      url.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: String(count))]
      payload = try await json(Request(url: url.url!, headers: provider.headers))
    case "exa":
      payload = try await post(provider, "search", .object([
        "query": .string(query), "numResults": .integer(count), "type": .string("auto"),
        "contents": .object(["highlights": .object(["numSentences": .integer(3)])]),
      ]))
    default:
      return try await codexSearch(query, count: count, provider: provider)
    }
    let results = provider.dialect == "brave" ? payload["web"]["results"].list : payload["results"].list
    let sources = results.prefix(count).compactMap { item -> WebSearchResult.Source? in
      guard let url = item["url"].text else { return nil }
      let snippet = item["description"].text ?? item["highlights"].list.compactMap(\.text).joined(separator: "\n")
      let published = item[provider.dialect == "brave" ? "page_age" : "publishedDate"].text
      return .init(title: item["title"].text ?? url, url: url, snippet: snippet, published: published)
    }
    return .init(query: query, provider: provider.provider, sources: sources)
  }

  private func codexSearch(_ query: String, count: Int, provider: Resolved) async throws -> WebSearchResult {
    let body: JSONValue = .object([
      "model": .string(provider.model), "store": .bool(false), "stream": .bool(true),
      "instructions": .string("Search the web for the user's query. Return useful factual snippets with source citations for up to \(count) results. Always use web_search."),
      "input": .array([.object(["role": .string("user"), "content": .array([.object(["type": .string("input_text"), "text": .string(query)])])])]),
      "tools": .array([.object(["type": .string("web_search")])]),
      "tool_choice": .string("required"),
      "include": .array([.string("web_search_call.action.sources")]),
    ])
    let response = try await send(Request(url: provider.baseURL.appendingPathComponent("responses"), method: .post, headers: provider.headers, body: try .json(body)))
    let text: String
    do { text = try await response.body.text(upTo: 8 << 20) }
    catch is CancellationError { throw CancellationError() }
    catch { throw CapabilityError(.providerUnavailable, "Codex search response could not be read.") }
    var completed: JSONValue?
    var doneItems: [JSONValue] = []
    for line in text.split(separator: "\n") where line.hasPrefix("data: ") {
      guard let event = JSONValue.parse(String(line.dropFirst(6))) else { continue }
      if ["response.failed", "error"].contains(event["type"].text) {
        throw CapabilityError(.providerUnavailable, "Codex search failed.")
      }
      if event["type"].text == "response.output_item.done", event["item"] != .null { doneItems.append(event["item"]) }
      if event["type"].text == "response.completed" { completed = event["response"] }
    }
    guard let completed else { throw CapabilityError(.providerUnavailable, "Codex search ended without a completed response.") }
    var sources: [WebSearchResult.Source] = []
    var snippets: [String] = []
    let output = completed["output"].list
    for item in output.isEmpty ? doneItems : output {
      for source in item["action"]["sources"].list {
        if let url = source["url"].text {
          sources.append(.init(title: source["title"].text ?? url, url: url))
        }
      }
      for content in item["content"].list {
        if let text = content["text"].text { snippets.append(text) }
        for citation in content["annotations"].list where citation["type"].text == "url_citation" {
          if let url = citation["url"].text {
            sources.append(.init(title: citation["title"].text ?? url, url: url))
          }
        }
      }
    }
    var seen: Set<String> = []
    sources = sources.filter { seen.insert($0.url).inserted }
    return .init(query: query, provider: provider.provider, sources: Array(sources.prefix(count)), text: snippets.isEmpty ? nil : snippets.joined(separator: "\n"))
  }
}
