/// How a recorded caller spelling names whom an exec or a script acts for: a session's id, an observer's member
/// (`<name>@<group>`), or a person's `@<account>`.
public enum ExecCallerSpelling {
  /// Whom a person's execs are recorded as: `@<account>`, which no observer member or session id takes.
  public static func person(_ account: AccountID) -> String { "@" + account.rawValue }

  /// The account a `@<account>` caller names; nil for every other spelling.
  public static func personAccount(_ caller: String) -> AccountID? {
    caller.first == "@" ? AccountID(rawValue: String(caller.dropFirst())) : nil
  }

  /// Whether a recorded caller is a sessionless script's: an observer's member or a person's, never a session's id.
  public static func isMember(_ caller: String) -> Bool { caller.contains("@") }

  /// The session a caller spelling names, for a spelling that is no member's.
  public static func session(_ caller: String) -> SessionID? {
    isMember(caller) ? nil : SessionID(rawValue: caller)
  }
}
