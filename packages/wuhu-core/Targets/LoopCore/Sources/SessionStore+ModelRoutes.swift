import struct SessionDomain.ModelRouteFailure
import struct SessionDomain.SessionID
import struct SessionDomain.SessionModelRoute
import struct SpaceCore.SessionStore

public extension SessionStore {
  func modelRoute(_ id: SessionID) async throws -> SessionModelRoute? {
    try space.worker.cell(SessionCell.ID(id.rawValue)).modelRoute()
  }

  func modelRouteHistory(_ id: SessionID) async throws -> [SessionModelRoute] {
    try space.worker.cell(SessionCell.ID(id.rawValue)).modelRouteHistory()
  }

  func updateInferenceModelRouteFailure(_ id: SessionID, expectedEpoch: String, failure: ModelRouteFailure?) async throws {
    space.worker.send(SessionCell.ID(id.rawValue)).updateInferenceModelRouteFailure(expectedEpoch: expectedEpoch, failure: failure)
  }

  func establishInferenceModelRoute(_ id: SessionID, route: SessionModelRoute) async throws -> SessionModelRoute {
    let address = SessionCell.ID(id.rawValue)
    if let held = try space.worker.cell(address).modelRoute(),
       held.group != nil || route.group != nil || (held.specifier == route.specifier && held.bindingFingerprint == route.bindingFingerprint)
    {
      return held
    }
    space.worker.send(address).establishInferenceModelRoute(route)
    return route
  }
}
