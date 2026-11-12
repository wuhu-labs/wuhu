#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineContract
import SpaceCore
import StructuredQueries
import Wuwei
import WuweiQueries

func registerMachineReleases(space: Space, version: String, client: MachineReleaseClient) throws {
  let worker = space.worker
  worker.provide(client)
  worker.register(.job(MachineReleaseJob.self))
  try worker.create(MachineReleaseJob.singleton, params: .init())
  if MachineV2ReleaseVersion.isValid(version) { worker.send(.resolve(version), to: MachineReleaseJob.singleton) }
}

@Job
struct MachineReleaseJob {
  static let singleton = ID("releases")
  static let schema = [
    "CREATE TABLE machine_release_resolutions (\(ownerColumn), version TEXT NOT NULL UNIQUE, resolution TEXT NOT NULL, artifacts TEXT NOT NULL, looked_up_at INTEGER, requested INTEGER NOT NULL)",
  ]

  struct Params: Codable {}
  enum Message: Codable { case resolve(String) }

  func resolution(for version: String) -> MachineReleaseClient.Resolution? {
    db.rows(MachineReleaseRow.where { $0.version.eq(#bind(version)) }).first?.answer
  }

  nonisolated(nonsending) mutating func start() async throws -> Outcome {
    let client = ctx.dependency(MachineReleaseClient.self)
    while true {
      try Task.checkCancellation()
      if let row = db.rows(MachineReleaseRow.where(\.requested)).first {
        let answer = try await ctx.effect { try await client.lookup(row.version) }
        try Task.checkCancellation()
        let at = ctx.now.milliseconds
        try db.execute(MachineReleaseRow.where { $0.version.eq(#bind(row.version)) }.update {
          $0.resolution = #bind(answer.label)
          $0.artifacts = #bind(answer.artifacts)
          $0.lookedUpAt = #bind(at)
          $0.requested = false
        })
      } else if let message = try await ctx.receive(within: .zero) {
        switch message {
        case let .resolve(version):
          if let row = db.rows(MachineReleaseRow.where { $0.version.eq(#bind(version)) }).first {
            if !row.answer.isFinal, row.lookedUpAt == nil || ctx.now.milliseconds - row.lookedUpAt! >= 60000 {
              try db.execute(MachineReleaseRow.where { $0.version.eq(#bind(version)) }.update { $0.requested = true })
            }
          } else {
            try db.execute(MachineReleaseRow.insert { MachineReleaseRow(version: version) })
          }
        }
      } else {
        return .hibernate
      }
    }
  }
}

@Table("machine_release_resolutions")
private struct MachineReleaseRow: Owned {
  var version: String
  var resolution = "unreachable"
  @Column(as: [MachineV2Artifact].JSONRepresentation.self) var artifacts: [MachineV2Artifact] = []
  @Column("looked_up_at") var lookedUpAt: Int64?
  var requested = true

  var answer: MachineReleaseClient.Resolution {
    switch resolution {
    case "published": .published(artifacts)
    case "unpublished": .unpublished
    case "unreachable": .unreachable
    default: preconditionFailure("invalid release resolution: \(resolution)")
    }
  }
}

extension MachineReleaseClient.Resolution {
  var isFinal: Bool { artifacts.count == MachineReleaseClient.platforms.count }
  var artifacts: [MachineV2Artifact] { if case let .published(artifacts) = self { artifacts } else { [] } }
  var label: String {
    switch self {
    case .published: "published"
    case .unpublished: "unpublished"
    case .unreachable: "unreachable"
    }
  }
}
