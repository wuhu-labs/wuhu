import Contract
import Foundation
import JSONValue
import MachineContract
import SpaceContract
import SpaceToolReference

@main
struct ContractExport {
  static func main() throws {
    let arguments = CommandLine.arguments
    if arguments.contains("--help") || arguments.contains("-h") {
      print(usage)
      return
    }
    let root = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : ".", isDirectory: true)
    var total = 0
    for (path, schemas) in registries {
      let directory = root.appendingPathComponent(path, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for (name, schema) in schemas {
        let file = directory.appendingPathComponent(SchemaDocument.fileName(forType: name))
        try SchemaDocument.document(named: name, schema: schema).write(to: file, atomically: true, encoding: .utf8)
      }
      total += schemas.count
    }
    let reference = root.appendingPathComponent(ToolReference.directory, isDirectory: true)
    try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
    let pages = ToolReference.pages()
    for (fileName, content) in pages {
      try content.write(to: reference.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }
    FileHandle.standardError.write(
      Data("contract-export: wrote \(total) schemas and \(pages.count) tool pages under \(root.path)\n".utf8),
    )
  }

  // The schema fixtures live under each contract target's test target so the
  // golden test can read them as a declared Bazel input (a sandboxed test only
  // sees its own resources; a package-level dir is not reachable via #filePath).
  static let registries: [(directory: String, schemas: [(name: String, schema: JSONValue)])] = [
    ("packages/wuhu-core/Targets/SpaceContract/Tests/contract", ContractSchemas.all),
    ("packages/wuhu-core/Targets/MachineContract/Tests/contract", MachineContractSchemas.all),
  ]

  static let usage = """
  contract-export — derive every registered contract target type's JSON Schema,
  and the space tools' reference pages, to disk.

  usage: contract-export [REPO_ROOT]

  Each registry is written to <REPO_ROOT>/<its Tests/contract dir>; REPO_ROOT
  defaults to the working directory. Under `bazel run` the working directory is
  not the repo root, so pass it explicitly:

    bazel run //packages/wuhu-core:contract-export -- "$PWD"

  Each registered type is written to <dir>/<kebab-name>.schema.json with
  "$schema" stamped as the first key. Refresh flow: edit a @Contract type,
  re-run this exporter, commit the changed contract/*.schema.json.
  SchemaGoldenTests fails until the checked-in schema files match the types.

  The space tools' pages are written to <REPO_ROOT>/\(ToolReference.directory),
  one per tool plus a README.md index; ToolReferenceTests fails until they match.
  """
}
