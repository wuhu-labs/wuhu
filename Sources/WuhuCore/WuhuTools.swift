import Foundation
import PiAgent
import PiAI

public enum WuhuTools {
  public static func simulatedWeatherTool() -> AnyAgentTool {
    struct Params: Decodable, Sendable {
      var city: String
    }

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "city": .object([
          "type": .string("string"),
          "description": .string("City name, e.g. San Francisco"),
        ]),
      ]),
      "required": .array([.string("city")]),
      "additionalProperties": .bool(false),
    ])

    return AnyAgentTool(
      name: "weather",
      label: "Weather",
      description: "Get simulated weather data for a city (demo tool; returns fake data).",
      parametersSchema: schema,
      execute: { (_: String, params: Params) in
        let report = simulatedWeather(for: params.city)
        let text = "\(report.city): \(report.temperatureC)°C, \(report.condition) (simulated)"
        return AgentToolResult(
          content: [.text(text)],
          details: .object([
            "city": .string(report.city),
            "temperatureC": .number(Double(report.temperatureC)),
            "condition": .string(report.condition),
            "source": .string("simulated"),
          ]),
        )
      },
    )
  }
}

private struct WeatherReport: Sendable {
  var city: String
  var temperatureC: Int
  var condition: String
}

private func simulatedWeather(for cityRaw: String) -> WeatherReport {
  let city = cityRaw.trimmingCharacters(in: .whitespacesAndNewlines)
  let normalized = city.lowercased()

  let fixed: [String: WeatherReport] = [
    "san francisco": .init(city: "San Francisco", temperatureC: 18, condition: "foggy"),
    "san diego": .init(city: "San Diego", temperatureC: 24, condition: "sunny"),
    "tokyo": .init(city: "Tokyo", temperatureC: 29, condition: "humid"),
    "new york": .init(city: "New York", temperatureC: 6, condition: "windy"),
  ]
  if let report = fixed[normalized] { return report }

  let hash = stableHash(normalized)
  let temp = 5 + Int(hash % 26) // 5..30
  let conditions = ["sunny", "cloudy", "rainy", "windy", "foggy"]
  let condition = conditions[Int((hash / 31) % UInt64(conditions.count))]
  return .init(city: city.isEmpty ? "Unknown" : city, temperatureC: temp, condition: condition)
}

private func stableHash(_ s: String) -> UInt64 {
  // FNV-1a 64-bit
  var hash: UInt64 = 14_695_981_039_346_656_037
  for b in s.utf8 {
    hash ^= UInt64(b)
    hash &*= 1_099_511_628_211
  }
  return hash
}
