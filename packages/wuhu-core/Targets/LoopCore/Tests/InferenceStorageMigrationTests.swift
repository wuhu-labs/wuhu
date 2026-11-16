#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import Scratch
@testable import SpaceCore
import Testing
import Wuwei

@Suite struct InferenceStorageMigrationTests {
  @Test func attemptTableDropsAndKeepsTheRetryState() async throws {
    let folder = try ScratchFolder("inference-storage-drop")
    let file = folder.url.appending(path: "jobs.sqlite")
    let database = try FileDatabase(path: file.path, synchronous: false)
    let worker = Worker(id: "test", storage: .shared(database), scheduler: LiveScheduler())
    try RawDatabase.open(file.path) { db throws in
      for statement in InferenceJob.schema.prefix(2) { try db.execute(sql: statement) }
      try db.execute(sql: """
      INSERT INTO wuwei_schema (kind, applied) VALUES ('\(InferenceJob.kind)', 2);
      INSERT INTO inference_steps (owner, attempts, backoff_attempt, idle_timeouts, bounded_failures, waited_ms, retry_at, outcome)
        VALUES ('step', 4, 2, 1, 0, 3000, 123.5, NULL);
      INSERT INTO inference_attempts (id, owner, failure) VALUES ('attempt', 'step', 'transient');
      """)
    }
    worker.register(.job(InferenceJob.self))
    let reopened = Worker(id: "reopened", storage: .shared(database), scheduler: LiveScheduler(), registrations: [.job(InferenceJob.self)])
    try RawDatabase.open(file.path) { db throws in
      #expect(try !db.tableExists("inference_attempts"))
      #expect(try db.strings("SELECT owner || '|' || attempts || '|' || backoff_attempt || '|' || idle_timeouts || '|' || bounded_failures || '|' || waited_ms || '|' || retry_at FROM inference_steps WHERE outcome IS NULL") == ["step|4|2|1|0|3000|123.5"])
      #expect(try db.int("SELECT applied FROM wuwei_schema WHERE kind = '\(InferenceJob.kind)'") == 3)
    }
    await worker.quiesce()
    worker.release()
    await reopened.quiesce()
    reopened.release()
  }
}
