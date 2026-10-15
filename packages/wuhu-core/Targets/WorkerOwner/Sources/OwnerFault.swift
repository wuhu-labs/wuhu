import enum Credentials.ChatGPTAuthError
import enum LoopCore.SessionError
import struct LoopCore.SessionExecutionRetired
import enum MachineChannel.ChannelError
import struct MachineContract.MachineError
import struct OperationProtocol.OperationError
import struct SessionDomain.ExecutorSpecError
import struct SessionDomain.ExecutorUnavailableError
import struct SessionDomain.SessionID
import struct SessionTools.ScriptError
import struct SessionTools.ScriptIdentityUnavailable
import struct SessionTools.SessionControlRefusal
import enum SpaceContract.ErrorCode
import enum SpaceCore.PortableHandoffConflict
import enum SpaceCore.SessionStoreError
import enum SpaceCore.SpaceError
import struct SpaceCore.StaleCompactClaim
import struct SpaceCore.UnresolvedCompactClaim
import enum SpaceTools.ToolRunError
import enum SpaceTools.Wire
import struct WorkerProtocol.WorkerProtocolError
import enum WuhuAI.InferenceError

struct OwnerFault: Codable, Sendable {
  let kind: String
  let fields: [String]
  let inference: InferenceFailureSnapshot?
  let tool: ToolFailureSnapshot?
  let space: SpaceFailureSnapshot?
  let operation: OperationError?
  let machine: MachineError?
  init(_ error: any Error) {
    operation = error as? OperationError
    if case let .some(.remote(value)) = error as? ChannelError { machine = value } else { machine = nil }
    space = (error as? SpaceError).map(SpaceFailureSnapshot.init)
    if let error = error as? ToolRunError { tool = .init(error) }

    else { tool = nil }
    inference = (error as? InferenceError).map(InferenceFailureSnapshot.init)
    if operation != nil { kind = "machine.operation"; fields = []; return }
    if space != nil { kind = "space.failure"; fields = []; return }
    if tool != nil { kind = "tool.failure"; fields = []; return }
    if inference != nil { kind = "inference.failure"; fields = []; return }
    switch error {
    case let error as ScriptError: kind = "script.failure"; fields = [error.description]
    case ChannelError.severed: kind = "machine.severed"; fields = []
    case let ChannelError.protocolViolation(message): kind = "machine.protocol"; fields = [message]
    case ChannelError.remote: kind = "machine.remote"; fields = []
    case let error as ScriptIdentityUnavailable: kind = "identity.unavailable"; fields = [error.message, error.code]
    case let error as SessionControlRefusal: kind = "tool.control-refused"; fields = [error.message, error.reason == .busy ? "busy" : "other"]
    case let ChatGPTAuthError.loginRequired(detail): kind = "credential.loginRequired"; fields = [detail]
    case let SessionStoreError.unknownSession(value): kind = "store.unknownSession"; fields = [value]
    case let SessionStoreError.archiveGraceExpired(value): kind = "store.archiveGraceExpired"; fields = [value]
    case let SessionStoreError.busyForRestart(value): kind = "store.busyForRestart"; fields = [value]
    case let SessionStoreError.requestDeadlineWithoutFireDate(value): kind = "store.requestDeadlineWithoutFireDate"; fields = [value]
    case let SessionStoreError.restartOfArchivedSession(value): kind = "store.restartOfArchivedSession"; fields = [value]
    case let SessionStoreError.parentUnavailableForCreation(value): kind = "store.parentUnavailableForCreation"; fields = [value]
    case let SessionStoreError.unknownMessage(value): kind = "store.unknownMessage"; fields = [value]
    case let SessionStoreError.unknownConversation(value): kind = "store.unknownConversation"; fields = [value]
    case let SessionStoreError.replyTargetInAnotherConversation(value): kind = "store.replyTargetInAnotherConversation"; fields = [value]
    case let SessionStoreError.selfDirectMessage(value): kind = "store.selfDirectMessage"; fields = [value]
    case let SessionStoreError.taskHasNoBox(value): kind = "store.taskHasNoBox"; fields = [value]
    case let SessionStoreError.taskTakesNoHumanInput(value): kind = "store.taskTakesNoHumanInput"; fields = [value]
    case let SessionStoreError.noParent(value): kind = "store.noParent"; fields = [value]
    case let SessionStoreError.notTheParent(value): kind = "store.notTheParent"; fields = [value]
    case let SessionStoreError.requestAlreadyOpen(value): kind = "store.requestAlreadyOpen"; fields = [value]
    case let SessionStoreError.unknownRequest(value): kind = "store.unknownRequest"; fields = [value]
    case let SessionStoreError.unusableTitle(value): kind = "store.unusableTitle"; fields = [value]
    case let SessionStoreError.tooDeep(value): kind = "store.tooDeep"; fields = [value]
    case let SessionStoreError.notInCharge(first, second): kind = "store.notInCharge"; fields = [first, second]
    case let SessionStoreError.mayNotArchive(first, second): kind = "store.mayNotArchive"; fields = [first, second]
    case let SessionStoreError.modelRouteInvalid(first, second): kind = "store.modelRouteInvalid"; fields = [first, second]
    case SessionStoreError.humanAgentDirectMessage: kind = "store.humanAgentDirectMessage"; fields = []
    case let SessionError.unreadableData(id): kind = "execution.unreadableData"; fields = [id.rawValue]
    case SessionError.archiveGraceExpired: kind = "execution.archiveGraceExpired"; fields = []
    case SessionError.archiveInProgress: kind = "execution.archiveInProgress"; fields = []
    case SessionError.archiveReservationLost: kind = "execution.archiveReservationLost"; fields = []
    case PortableHandoffConflict.generationChanged: kind = "handoff.generationChanged"; fields = []
    case PortableHandoffConflict.transcriptChanged: kind = "handoff.transcriptChanged"; fields = []
    case PortableHandoffConflict.routeChanged: kind = "handoff.routeChanged"; fields = []
    case is SessionExecutionRetired: kind = "execution.retired"; fields = []
    case is StaleCompactClaim: kind = "compact.stale"; fields = []
    case is UnresolvedCompactClaim: kind = "compact.unresolved"; fields = []
    case is ExecutorUnavailableError: kind = "executor.unavailable"; fields = []
    case let error as ExecutorSpecError: kind = "executor.invalid"; fields = [error.message]
    default: kind = "owner.failure"; fields = []
    }
  }

  func error() throws -> any Error {
    if kind == "machine.operation", let operation { return operation }
    if kind == "machine.remote", let machine { return ChannelError.remote(machine) }
    if kind == "space.failure", let space { return try space.error() }
    if kind == "tool.failure", let tool { return try tool.error() }
    if kind == "inference.failure", let inference { return try inference.error() }
    return switch (kind, fields.count) {
    case ("script.failure", 1): ScriptError(fields[0])
    case ("machine.severed", 0): ChannelError.severed
    case ("machine.protocol", 1): ChannelError.protocolViolation(fields[0])
    case ("identity.unavailable", 2): ScriptIdentityUnavailable(message: fields[0], code: fields[1])
    case ("tool.control-refused", 2): SessionControlRefusal(fields[0], reason: fields[1] == "busy" ? .busy : .other)
    case ("credential.loginRequired", 1): ChatGPTAuthError.loginRequired(detail: fields[0])
    case ("store.unknownSession", 1): SessionStoreError.unknownSession(fields[0])
    case ("store.archiveGraceExpired", 1): SessionStoreError.archiveGraceExpired(fields[0])
    case ("store.busyForRestart", 1): SessionStoreError.busyForRestart(fields[0])
    case ("store.requestDeadlineWithoutFireDate", 1): SessionStoreError.requestDeadlineWithoutFireDate(fields[0])
    case ("store.restartOfArchivedSession", 1): SessionStoreError.restartOfArchivedSession(fields[0])
    case ("store.parentUnavailableForCreation", 1): SessionStoreError.parentUnavailableForCreation(fields[0])
    case ("store.unknownMessage", 1): SessionStoreError.unknownMessage(fields[0])
    case ("store.unknownConversation", 1): SessionStoreError.unknownConversation(fields[0])
    case ("store.replyTargetInAnotherConversation", 1): SessionStoreError.replyTargetInAnotherConversation(fields[0])
    case ("store.selfDirectMessage", 1): SessionStoreError.selfDirectMessage(fields[0])
    case ("store.taskHasNoBox", 1): SessionStoreError.taskHasNoBox(fields[0])
    case ("store.taskTakesNoHumanInput", 1): SessionStoreError.taskTakesNoHumanInput(fields[0])
    case ("store.noParent", 1): SessionStoreError.noParent(fields[0])
    case ("store.notTheParent", 1): SessionStoreError.notTheParent(fields[0])
    case ("store.requestAlreadyOpen", 1): SessionStoreError.requestAlreadyOpen(fields[0])
    case ("store.unknownRequest", 1): SessionStoreError.unknownRequest(fields[0])
    case ("store.unusableTitle", 1): SessionStoreError.unusableTitle(fields[0])
    case ("store.tooDeep", 1): SessionStoreError.tooDeep(fields[0])
    case ("store.notInCharge", 2): SessionStoreError.notInCharge(fields[0], actor: fields[1])
    case ("store.mayNotArchive", 2): SessionStoreError.mayNotArchive(fields[0], actor: fields[1])
    case ("store.modelRouteInvalid", 2): SessionStoreError.modelRouteInvalid(group: fields[0], member: fields[1])
    case ("store.humanAgentDirectMessage", 0): SessionStoreError.humanAgentDirectMessage
    case ("execution.unreadableData", 1): SessionError.unreadableData(SessionID(rawValue: fields[0]))
    case ("execution.archiveGraceExpired", 0): SessionError.archiveGraceExpired
    case ("execution.archiveInProgress", 0): SessionError.archiveInProgress
    case ("execution.archiveReservationLost", 0): SessionError.archiveReservationLost
    case ("handoff.generationChanged", 0): PortableHandoffConflict.generationChanged
    case ("handoff.transcriptChanged", 0): PortableHandoffConflict.transcriptChanged
    case ("handoff.routeChanged", 0): PortableHandoffConflict.routeChanged
    case ("execution.retired", 0): SessionExecutionRetired()
    case ("compact.stale", 0): StaleCompactClaim()
    case ("compact.unresolved", 0): UnresolvedCompactClaim()
    case ("executor.unavailable", 0): ExecutorUnavailableError()
    case ("executor.invalid", 1): ExecutorSpecError(fields[0])
    case ("owner.failure", 0): WorkerProtocolError(.remoteFailure, message: "Parent owner operation failed")
    default: throw WorkerProtocolError(.invalidMessage, message: "Invalid owner fault snapshot")
    }
  }
}

struct ToolFailureSnapshot: Codable, Sendable {
  let code: ErrorCode
  let message: String
  let hint: String?
  let token: String?
  init(_ error: ToolRunError) {
    switch error {
    case let .undecodableInput(message): code = .invalidArgument; self.message = message; hint = nil; token = nil
    case let .failed(code, message, hint, token): self.code = code; self.message = message; self.hint = hint; self.token = token
    }
  }

  func error() throws -> ToolRunError { .failed(code: code, message: message, hint: hint, token: token) }
}
