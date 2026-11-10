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

struct ReadArguments: Decodable {
  var path: String
  var lines: String?
}

struct WriteArguments: Decodable {
  var path: String
  var content: String
}

struct EditArguments: Decodable {
  struct Edit: Decodable {
    var old: String
    var new: String
  }

  var path: String
  var edits: [Edit]
}
