/// What a space operation refuses with: the space's error vocabulary, shared by every family so a refusal keeps one
/// spelling on its way out.
public enum SpaceError: Error, Equatable, Sendable {
  case notFound(String)
  case notAFile(String)
  case notATable(String)
  case notADirectory(String)
  case pathIsDirectory(String)
  case alreadyExists(String)
  case malformedPubkey(String)
  case versionMismatch(String)
  case invalidRevision(Int)
  case columnCountMismatch(String)
  case columnTypeChanged(String)
  case invalidTableHeader(String)
  case invalidCellValue(String)
  case reservedTablePath(String)
  case lastAdmin(String)
  case readOnlyView(String)
  /// A write, move or remove under `wuhu://system/`, which ships in the binary.
  case systemReadOnly(String)
  /// A write, move or remove under `/_/session-transcripts/` or `/_/rendered/`, views of what requests sent.
  case sentViewReadOnly(String)
  case foreignHome(path: String, owner: String)
  case queryNotReadOnly
  case queryForbiddenTable(String)
  case queryResultTooLarge(byteLimit: Int)
  case listingResultTooLarge(byteLimit: Int)
  case unknownRelation(String)
  case templateInvalid(String)
  case importInvalid(String)
  case vocabularyFrozen(String)
  case invalidHandle(String)
  case handleTaken(String)
  case invalidMachineName(String)
  case machineNameTaken(String)
  /// The name is held by a machine; deleting that machine frees it.
  case machineNameTakenByMachine(String)
  case unknownDevice(String)
  case invalidDeviceKind(String)
  /// The refusal's reason, naming the device name.
  case invalidDeviceName(String)
  /// The refusal's reason, naming the group name.
  case invalidGroupName(String)
  /// The database predates a schema compaction this binary requires.
  case needsMigration(String)
  case unknownMigrations([String])
  /// Only a person administers a space.
  case notAPerson(String)
  /// A group the actor's group does not read, named as a new session's home.
  case groupForbidden(String)
  /// A write by someone the group does not admit: its instructions, or the
  /// settings group.
  case forbiddenWrite(path: String, group: String)
  /// A read edge into a person's own group: it has one member, its owner.
  /// Administering the settings group is the account admin verb's, alone, so
  /// the last-admin guard cannot be skipped.
  case settingsGroupAccess
  /// Text a live node (`.wmd`, `.canvas`) cannot hold: `line` is nil when the whole text is refused.
  case liveSyntax(path: String, line: Int?, reason: String)
  /// A move whose source document holds edits its file lacks, after the host tried to commit them.
  case liveBusy(String)
}
