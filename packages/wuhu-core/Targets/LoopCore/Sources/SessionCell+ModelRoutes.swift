import struct SessionDomain.ModelRouteFailure
import struct SessionDomain.SessionModelRoute
import enum SpaceCore.SessionModelRoutes

extension SessionCell {
  func modelRoute() throws -> SessionModelRoute? {
    try SessionModelRoutes.route(id.key, in: db)
  }

  func modelRouteHistory() throws -> [SessionModelRoute] {
    try SessionModelRoutes.history(id.key, in: db)
  }

  mutating func acceptInferenceModelRouteFailure(expectedEpoch: String, failure: ModelRouteFailure?) throws {
    try SessionModelRoutes.updateFailureIfCurrent(id.key, expectedEpoch: expectedEpoch, failure: failure, in: &db)
  }

  mutating func acceptInferenceModelRoute(_ route: SessionModelRoute) throws {
    _ = try SessionModelRoutes.establish(id.key, route: route, in: &db)
  }

  mutating func writeModelRoute(_ route: SessionModelRoute?) throws {
    try SessionModelRoutes.write(id.key, route: route, in: &db)
  }
}
