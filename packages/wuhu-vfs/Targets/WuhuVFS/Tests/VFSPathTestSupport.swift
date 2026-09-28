import WuhuVFS

func path(_ components: [String]) throws -> VFSPath {
  try VFSPath(components: components.map { component in
    guard let name = VFSPathComponent(rawValue: component) else {
      throw VFSPathError.invalidComponent(component)
    }
    return name
  })
}

func path(_ absoluteFilePath: String) throws -> VFSPath {
  try VFSPath(absoluteFilePath: absoluteFilePath)
}
