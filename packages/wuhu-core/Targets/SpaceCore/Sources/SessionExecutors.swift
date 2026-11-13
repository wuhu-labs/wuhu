import SessionDomain

extension Sessions {
  public static func concreteExecutor(_ executor: SessionExecutor, route: SessionModelRoute?) throws -> SessionExecutor {
    if case let .modelGroup(group, effort) = executor {
      guard let route, route.group == group, route.member != nil, route.specifier.effort == effort else {
        throw ExecutorSpecError("a model group requires a matching prepared placement")
      }
      return .kernel(route.specifier)
    }
    guard route?.group == nil else { throw ExecutorSpecError("a direct target cannot carry group intent") }
    return executor
  }
}
