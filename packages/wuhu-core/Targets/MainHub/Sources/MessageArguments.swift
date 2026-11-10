import enum JSONValue.JSONValue
import struct SpaceCore.RequestTerms
import struct SpaceCore.RequestTermsError

public struct SendMessageArguments: Decodable, Sendable {
  public var message: String
  public var conversation: String?
  public var session: String?
  public var replyTarget: String?
  public var attachments: [String]?

  public init(message: String, conversation: String? = nil, session: String? = nil, replyTarget: String? = nil, attachments: [String]? = nil) {
    self.message = message; self.conversation = conversation; self.session = session; self.replyTarget = replyTarget; self.attachments = attachments
  }

  enum CodingKeys: String, CodingKey {
    case message
    case conversation
    case session
    case replyTarget = "reply_target"
    case attachments
  }
}

public struct RequestArguments: Decodable, Sendable {
  public var task: String
  public var message: String
  public var stallSeconds: Double?
  public var terms: RequestTermsArguments

  public init(task: String, message: String, stallSeconds: Double? = nil, terms: RequestTermsArguments = .init()) {
    self.task = task; self.message = message; self.stallSeconds = stallSeconds; self.terms = terms
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    task = try container.decode(String.self, forKey: .task)
    message = try container.decode(String.self, forKey: .message)
    stallSeconds = try container.decodeIfPresent(Double.self, forKey: .stallSeconds)
    terms = try RequestTermsArguments(from: decoder)
  }

  enum CodingKeys: String, CodingKey {
    case task
    case message
    case stallSeconds = "stall_seconds"
  }
}

/// A request's schema and fields as a caller spells them: flat on the request
/// tool, under `request` on create_session.
public struct RequestTermsArguments: Decodable, Sendable, Hashable {
  public var schema: JSONValue?
  public var fields: JSONValue?

  public init(schema: JSONValue? = nil, fields: JSONValue? = nil) {
    self.schema = schema; self.fields = fields
  }

  func terms() throws -> RequestTerms {
    do throws(RequestTermsError) {
      return try RequestTerms(schema: schema, fields: fields)
    } catch {
      throw ToolProblem(error.message, code: "invalidArgument")
    }
  }
}
