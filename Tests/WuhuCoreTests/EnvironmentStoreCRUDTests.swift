import Foundation
import Testing
import WuhuAPI
import WuhuCore

struct EnvironmentStoreCRUDTests {
  @Test func createAndGetEnvironment_byIDAndName() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")

    let created = try await store.createEnvironment(.init(
      name: "env-1",
      type: .local,
      path: "/tmp/env-1",
    ))

    let fetchedByID = try await store.getEnvironment(identifier: created.id)
    #expect(fetchedByID.id == created.id)
    #expect(fetchedByID.name == created.name)
    #expect(fetchedByID.type == created.type)
    #expect(fetchedByID.path == created.path)
    #expect(fetchedByID.templatePath == created.templatePath)
    #expect(fetchedByID.startupScript == created.startupScript)

    let fetchedByName = try await store.getEnvironment(identifier: created.name)
    #expect(fetchedByName.id == created.id)
    #expect(fetchedByName.name == created.name)
    #expect(fetchedByName.type == created.type)
    #expect(fetchedByName.path == created.path)
    #expect(fetchedByName.templatePath == created.templatePath)
    #expect(fetchedByName.startupScript == created.startupScript)
  }

  @Test func listEnvironments_ordersByNameAscending() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")

    _ = try await store.createEnvironment(.init(name: "b-env", type: .local, path: "/tmp/b"))
    _ = try await store.createEnvironment(.init(name: "a-env", type: .local, path: "/tmp/a"))
    _ = try await store.createEnvironment(.init(name: "c-env", type: .local, path: "/tmp/c"))

    let listed = try await store.listEnvironments()
    #expect(listed.map(\.name) == ["a-env", "b-env", "c-env"])
  }

  @Test func updateEnvironment_supportsPartialUpdateAndClearsNullableFields() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")

    let created = try await store.createEnvironment(.init(
      name: "tmpl",
      type: .folderTemplate,
      path: "/tmp/workspaces",
      templatePath: "/tmp/template",
      startupScript: "startup.sh",
    ))

    let updated = try await store.updateEnvironment(
      identifier: created.name,
      request: .init(
        name: "tmpl-2",
        path: "/tmp/workspaces-2",
        templatePath: .some(nil),
        startupScript: .some(nil),
      ),
    )

    #expect(updated.id == created.id)
    #expect(updated.type == .folderTemplate)
    #expect(updated.name == "tmpl-2")
    #expect(updated.path == "/tmp/workspaces-2")
    #expect(updated.templatePath == nil)
    #expect(updated.startupScript == nil)

    let fetched = try await store.getEnvironment(identifier: created.id)
    #expect(fetched.id == updated.id)
    #expect(fetched.name == updated.name)
    #expect(fetched.type == updated.type)
    #expect(fetched.path == updated.path)
    #expect(fetched.templatePath == updated.templatePath)
    #expect(fetched.startupScript == updated.startupScript)
  }

  @Test func deleteEnvironment_removesRow() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")

    let created = try await store.createEnvironment(.init(name: "to-delete", type: .local, path: "/tmp/x"))
    try await store.deleteEnvironment(identifier: created.id)

    await #expect(throws: WuhuEnvironmentResolutionError.self) {
      _ = try await store.getEnvironment(identifier: created.id)
    }
  }

  @Test func createEnvironment_enforcesUniqueName() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")

    _ = try await store.createEnvironment(.init(name: "dup", type: .local, path: "/tmp/1"))

    await #expect(throws: Error.self) {
      _ = try await store.createEnvironment(.init(name: "dup", type: .local, path: "/tmp/2"))
    }
  }
}
