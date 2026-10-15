import enum Credentials.ChatGPTAuthError
import enum LoopCore.SessionError
import struct LoopCore.SessionExecutionRetired
import struct SessionDomain.ExecutorSpecError
import struct SessionDomain.ExecutorUnavailableError
import struct SessionDomain.SessionID
import enum SpaceCore.PortableHandoffConflict
import enum SpaceCore.SessionStoreError
import struct SpaceCore.StaleCompactClaim
import struct SpaceCore.UnresolvedCompactClaim
import struct WorkerProtocol.WorkerProtocolError
import enum WuhuAI.InferenceError

struct OwnerFault: Codable, Sendable {
  let kind: String
  let fields: [String]
  let inference: InferenceFailureSnapshot?
  init(_ error: any Error) {
    inference = (error as? InferenceError).map(InferenceFailureSnapshot.init)
    if inference != nil { kind = "inference.failure"; fields = []; return }
    switch error {
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
    if kind == "inference.failure", let inference { return try inference.error() }
    return switch (kind, fields.count) {
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
