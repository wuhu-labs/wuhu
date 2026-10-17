import Crypto
import Foundation
@testable import ImageRetention
import Scratch
import Testing

@Suite struct ImageRetentionTests {
  private func source(_ scratch: ScratchFolder) throws -> String {
    let path = scratch.url.appendingPathComponent("wuhu")
    try Data("immutable executable".utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    return path.path
  }

  @Test func legacyCopySurvivesSourceRemovalAndReopen() throws {
    let scratch = try ScratchFolder("image-retention")
    defer { scratch.remove() }
    let binary = try source(scratch)
    let root = scratch.url.appendingPathComponent("images").path
    let reference = try ImageRetention.transaction(root: root) { _ in try seedLegacyImage(root: root, source: binary) }
    try FileManager.default.removeItem(atPath: binary)
    try ImageRetention.transaction(root: root) { store throws -> Void in
      #expect(try store.references() == [reference])
      try store.verifyImage(reference)
      #expect(throws: ImageRetentionError.invalidEvidence) { try store.release(reference) }
    }
  }

  @Test func liveProcessCannotReleaseAndReusedPIDCannotReleaseAnotherIncarnation() throws {
    let scratch = try ScratchFolder("image-retention")
    defer { scratch.remove() }
    let binary = try source(scratch)
    let root = scratch.url.appendingPathComponent("images").path
    try ImageRetention.transaction(root: root) { store throws -> Void in
      let bound = try seedLegacyImage(root: root, source: binary, processID: getpid(), birth: imageProcessBirth(getpid()))
      #expect(throws: ImageRetentionError.processStillLive) { try store.release(bound) }
      let live = try seedLegacyImage(root: root, source: binary, processID: getpid(), birth: imageProcessBirth(getpid()))
      let reused = ImageReference(id: bound.id, digest: bound.digest, owner: bound.owner, processID: bound.processID, birth: "positively-different-old-birth")
      try JSONEncoder().encode(reused).write(to: URL(fileURLWithPath: root + "/" + reused.id.uuidString + ".json"))
      try store.release(reused)
      try store.verifyImage(live)
      #expect(try store.references() == [live])
      #expect(try store.protects(binary: binary))
      try store.release(reused)
    }
  }

  @Test func corruptAndSubstitutedEvidenceRefusePruning() throws {
    let scratch = try ScratchFolder("image-retention")
    defer { scratch.remove() }
    let binary = try source(scratch)
    let root = scratch.url.appendingPathComponent("images").path
    let reference = try ImageRetention.transaction(root: root) { _ in try seedLegacyImage(root: root, source: binary) }
    let record = URL(fileURLWithPath: root + "/" + reference.id.uuidString + ".json")
    try Data("{}".utf8).write(to: record)
    #expect(throws: ImageRetentionError.invalidEvidence) { try ImageRetention.transaction(root: root) { try $0.protects(binary: binary) } }
    try FileManager.default.removeItem(at: record)
    try FileManager.default.createSymbolicLink(at: record, withDestinationURL: URL(fileURLWithPath: binary))
    #expect(throws: ImageRetentionError.invalidEvidence) { try ImageRetention.transaction(root: root) { try $0.protects(binary: binary) } }
  }

  @Test func concurrentLegacyReferenceChecksSerializeWithPruning() async throws {
    let scratch = try ScratchFolder("image-retention")
    defer { scratch.remove() }
    let binary = try source(scratch)
    let root = scratch.url.appendingPathComponent("images").path
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 12 {
        group.addTask {
          try ImageRetention.transaction(root: root) { store throws -> Void in
            let reference = try seedLegacyImage(root: root, source: binary)
            #expect(try store.protects(binary: binary))
            try store.verifyImage(reference)
          }
        }
      }
      try await group.waitForAll()
    }
    #expect(try ImageRetention.transaction(root: root) { try $0.references().count } == 12)
  }

  @Test func interruptedPublicationsRecoverTheirValidatedStageLinks() throws {
    let scratch = try ScratchFolder("image-stages")
    defer { scratch.remove() }
    let binary = try source(scratch)
    let root = scratch.url.appendingPathComponent("images").path
    let reference = try ImageRetention.transaction(root: root) { _ in try seedLegacyImage(root: root, source: binary) }
    for path in [reference.id.uuidString + ".json", reference.digest] {
      let temporary = root + "/.stage-" + UUID().uuidString
      try FileManager.default.linkItem(atPath: root + "/" + path, toPath: temporary)
      try ImageRetention.transaction(root: root) { store throws -> Void in
        try store.verify(reference)
        #expect(try store.references() == [reference])
      }
      #expect(!FileManager.default.fileExists(atPath: temporary))
    }
  }

  @Test func legacyOrphanRecoverySweepsOnlyUnreferencedVerifiedDigests() throws {
    let scratch = try ScratchFolder("image-orphans")
    defer { scratch.remove() }
    let binary = try source(scratch)
    let root = scratch.url.appendingPathComponent("images").path
    for _ in 0 ..< 2 {
      let reference = try ImageRetention.transaction(root: root) { _ in try seedLegacyImage(root: root, source: binary) }
      try FileManager.default.removeItem(atPath: root + "/" + reference.id.uuidString + ".json")
      try ImageRetention.transaction(root: root) { store throws -> Void in #expect(try store.references().isEmpty) }
      #expect(!FileManager.default.fileExists(atPath: root + "/" + reference.digest))
    }
  }

  @Test func preparationReconciliationRequiresAnUnlockedLeaseAndRetiredBoundBirth() throws {
    let scratch = try ScratchFolder("image-preparation")
    defer { scratch.remove() }
    let binary = try source(scratch)
    let root = scratch.url.appendingPathComponent("images").path
    var lease: LegacyImageLease?
    let reference = try ImageRetention.transaction(root: root) { _ in
      let reference = try seedLegacyImage(root: root, source: binary)
      lease = try LegacyImageLease(root: root, id: reference.id)
      return reference
    }
    try ImageRetention.transaction(root: root) { store throws -> Void in
      #expect(try store.references() == [reference])
      #expect(throws: ImageRetentionError.processStillLive) { try store.release(reference) }
    }
    withExtendedLifetime(lease) {}
    lease = nil
    #expect(try ImageRetention.transaction(root: root) { try $0.references().isEmpty })
    let bound = try ImageRetention.transaction(root: root) { _ in
      let reference = try seedLegacyImage(root: root, source: binary, processID: getpid(), birth: imageProcessBirth(getpid()))
      lease = try LegacyImageLease(root: root, id: reference.id)
      return reference
    }
    lease = nil
    try ImageRetention.transaction(root: root) { store throws -> Void in
      #expect(try store.references() == [bound])
      #expect(throws: ImageRetentionError.processStillLive) { try store.release(bound) }
    }
  }

  @Test func replacingLockInodeBeforeAcquisitionRefusesWithoutRunningTheTransaction() throws {
    let scratch = try ScratchFolder("image-lock-substitution")
    defer { scratch.remove() }
    let root = scratch.url.appendingPathComponent("images").path
    var invoked = false
    #expect(throws: ImageRetentionError.unsafeStorage) {
      try ImageRetention.transaction(root: root, beforeLock: {
        try FileManager.default.moveItem(atPath: root + "/lock", toPath: root + "/old-lock")
        try Data().write(to: URL(fileURLWithPath: root + "/lock"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root + "/lock")
      }) { _ in invoked = true }
    }
    #expect(!invoked)
  }

  @Test func closureErrorsRetainTheirOriginalType() throws {
    enum ClosureFailure: Error, Equatable { case expected }
    let scratch = try ScratchFolder("image-closure-error")
    defer { scratch.remove() }
    #expect(throws: ClosureFailure.expected) {
      try ImageRetention.transaction(root: scratch.url.appendingPathComponent("images").path) { _ in throw ClosureFailure.expected }
    }
  }

  @Test func recoveryRefusesExternallyLinkedStagesAndCorruptOrphans() throws {
    let scratch = try ScratchFolder("image-unsafe-recovery")
    defer { scratch.remove() }
    let binary = try source(scratch)
    let root = scratch.url.appendingPathComponent("images").path
    let reference = try ImageRetention.transaction(root: root) { _ in try seedLegacyImage(root: root, source: binary) }
    let stage = root + "/.stage-" + UUID().uuidString
    try Data("interrupted stage".utf8).write(to: URL(fileURLWithPath: stage))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage)
    let outside = scratch.url.appendingPathComponent("outside-stage-link").path
    try FileManager.default.linkItem(atPath: stage, toPath: outside)
    #expect(throws: ImageRetentionError.invalidEvidence) { try ImageRetention.transaction(root: root) { _ in } }
    #expect(FileManager.default.fileExists(atPath: stage))
    try FileManager.default.removeItem(atPath: outside)
    try FileManager.default.removeItem(atPath: root + "/" + reference.id.uuidString + ".json")
    let image = root + "/" + reference.digest
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: image)
    try Data("corrupt digest bytes".utf8).write(to: URL(fileURLWithPath: image))
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: image)
    #expect(throws: ImageRetentionError.imageChanged) { try ImageRetention.transaction(root: root) { _ in } }
    #expect(FileManager.default.fileExists(atPath: image))
  }
}

private struct LegacyImageRecord: Encodable {
  let id: UUID
  let digest: String
  let owner = "legacy-image"
  let processID: Int32?
  let birth: String?
}

func seedLegacyImage(root: String, source: String, id: UUID = UUID(), processID: Int32? = nil, birth: String? = nil) throws -> ImageReference {
  let bytes = try Data(contentsOf: URL(fileURLWithPath: source))
  let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  let image = URL(fileURLWithPath: root + "/" + digest)
  if !FileManager.default.fileExists(atPath: image.path) {
    try bytes.write(to: image)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: image.path)
  }
  let record = URL(fileURLWithPath: root + "/" + id.uuidString + ".json")
  let encoded = try JSONEncoder().encode(LegacyImageRecord(id: id, digest: digest, processID: processID, birth: birth))
  try encoded.write(to: record)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
  return try JSONDecoder().decode(ImageReference.self, from: encoded)
}

final class LegacyImageLease {
  private let descriptor: Int32
  init(root: String, id: UUID) throws {
    let path = root + "/.lease-" + id.uuidString
    descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw ImageRetentionError.unsafeStorage }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      _ = close(descriptor)
      throw ImageRetentionError.unsafeStorage
    }
  }

  deinit { _ = close(descriptor) }
}
