import JSONValue
import SessionDomain
import SpaceCore
import SpaceTools

func scriptChannel(_ arguments: [JSONValue], space: Space, session: SessionID) async -> JSONValue {
  await spaceAnswer {
    guard arguments.count == 2, let operation = arguments[0].stringValue, let fields = arguments[1].object else {
      throw ScriptError("channel operation wants an object")
    }
    let principal = try await space.principal(of: session)
    func people() throws -> [String] {
      guard case let .array(values)? = fields["people"], values.allSatisfy({ $0.stringValue != nil }) else {
        throw ScriptError("people must be an array of person identities")
      }
      return values.compactMap(\.stringValue)
    }
    func title() throws -> String? {
      switch fields["title"] {
      case nil, .null?: nil
      case let .string(value)?: value
      default: throw ScriptError("title must be a string or null")
      }
    }
    func id() throws -> ConversationID {
      guard let id = fields["id"]?.stringValue, !id.isEmpty else { throw ScriptError("channel id must be a nonempty string") }
      return ConversationID(id)
    }
    do {
      switch operation {
      case "create":
        guard Set(fields.keys).isSubset(of: ["title", "people"]) else { throw ScriptError("unsupported channel create option") }
        let id = try await space.sessions.createConversation(members: people(), title: title(), in: principal.group)
        return .string(id.rawValue)
      case "add", "remove":
        guard Set(fields.keys).isSubset(of: ["id", "people"]) else { throw ScriptError("unsupported channel member option") }
        if operation == "add" { try await space.sessions.addChannelMembers(id(), people: people(), as: principal) }
        else { try await space.sessions.removeChannelMembers(id(), people: people(), as: principal) }
      case "rename":
        guard Set(fields.keys).isSubset(of: ["id", "title"]) else { throw ScriptError("unsupported channel rename option") }
        try await space.sessions.renameChannel(id(), title: title(), as: principal)
      default: throw ScriptError("unknown channel operation")
      }
    } catch let error as ChannelError {
      throw ToolRunError.failed(code: .invalidArgument, message: "\(error)", hint: nil)
    } catch SessionStoreError.unknownConversation(let id) {
      throw ToolRunError.failed(code: .notFound, message: "unknown conversation: \(id)", hint: nil)
    }
    return .null
  }
}
