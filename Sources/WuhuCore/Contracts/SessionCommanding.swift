import Foundation

/// Transport-agnostic contract for issuing commands to a session.
///
/// This protocol is intentionally minimal and has no requirements yet. The goal is to
/// establish a stable “meaning boundary” in code before porting existing types.
protocol SessionCommanding: Actor {}

