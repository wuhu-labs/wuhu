import Wuwei

func fanOut(_ ctx: ObjectContext<Room>) async {
  await ctx.withTaskGroup(of: Int.self) { _ in }
  _ = Task.isCancelled
  let task: Task<Void, Never>? = nil
  _ = task
  var lines: [String] = []
  lines.append(contentsOf: ["a"])
  _ = String(decoding: Data(), as: UTF8.self)
}
