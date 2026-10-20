struct GenerateImageArguments: Decodable {
  var prompt: String
  var destination: String
  var provider: String?
  var model: String?
  var quality: String?
  var size: String?
}

struct GrepArguments: Decodable {
  var pattern: String
  var path: String?
  var matchLimit: Int?
  var hidden: Bool?
  var noIgnore: Bool?
  var step: String?

  enum CodingKeys: String, CodingKey {
    case pattern
    case path
    case matchLimit = "match_limit"
    case hidden
    case noIgnore = "no_ignore"
    case step
  }
}

struct FindArguments: Decodable {
  var glob: String
  var path: String?
  var matchLimit: Int?
  var hidden: Bool?
  var noIgnore: Bool?
  var step: String?

  enum CodingKeys: String, CodingKey {
    case glob
    case path
    case matchLimit = "match_limit"
    case hidden
    case noIgnore = "no_ignore"
    case step
  }
}

struct QueryArguments: Decodable {
  var sql: String
}
