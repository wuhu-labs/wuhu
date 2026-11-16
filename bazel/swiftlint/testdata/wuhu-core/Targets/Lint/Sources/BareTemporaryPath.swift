// temporaryDirectory NSTemporaryDirectory mkdtemp mkstemp
let mentioned = "temporaryDirectory NSTemporaryDirectory mkdtemp mkstemp"

func bare() -> URL {
  FileManager.default.temporaryDirectory
}

func excused() -> URL {
  // swiftlint:disable:next no_bare_temporary_path - the fixture's excused line
  FileManager.default.temporaryDirectory
}
