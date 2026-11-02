import NIOCore
import Wuwei

func fanOut() async {
  await withTaskGroup(of: Int.self) { _ in }
  await Swift.withThrowingTaskGroup(of: Int.self) { _ in }
}

func spawn() {
  Task { await fanOut() }
  Task.detached { await fanOut() }
  Task.immediate { await fanOut() }
  Task<Void, Never> { await fanOut() }
  DispatchQueue.global().async {}
}

func touch(_ url: URL) throws {
  _ = FileManager.default
  _ = URLSession.shared
  _ = try Data(contentsOf: url)
  _ = try String(contentsOfFile: "/etc/hosts")
  try Data().write(to: url)
}
