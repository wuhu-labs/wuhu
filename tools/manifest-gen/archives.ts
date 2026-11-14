import type { ModuleFragment } from './module.ts'

// `"**"` is the whole extracted tree; any other value names one file in it.
export interface TestArchive {
  url: string
  sha256: string
  filegroups: Record<string, string>
}

export type TestArchives = Record<string, TestArchive>

export function testArchiveRepos(archives: TestArchives | undefined): string[] {
  return Object.keys(archives ?? {})
}

function filegroupSources(pattern: string, source: string): string {
  if (pattern === '**') return 'glob(["**"])'
  if (
    pattern.includes('*') ||
    pattern.split('/').some((part) =>
      part === '' || part === '.' || part === '..'
    )
  ) {
    throw new Error(
      `${source} filegroup ${
        JSON.stringify(pattern)
      } must be "**" (the whole archive) or one relative file path.`,
    )
  }
  return `["${pattern}"]`
}

export function testArchiveFragment(
  archives: TestArchives,
  source: string,
): ModuleFragment {
  const blocks = Object.entries(archives).map(([repo, archive]) => {
    if (!/^[0-9a-f]{64}$/.test(archive.sha256 ?? '')) {
      throw new Error(`${source} archive ${repo} needs a hex sha256.`)
    }
    const groups = Object.entries(archive.filegroups ?? {})
    if (groups.length === 0) {
      throw new Error(`${source} archive ${repo} declares no filegroups.`)
    }
    const build = groups.map(([name, pattern]) =>
      `filegroup(\n    name = "${name}",\n    srcs = ${
        filegroupSources(pattern, source)
      },\n)\n`
    ).join('\n')
    return `http_archive(
    name = "${repo}",
    build_file_content = """
package(default_visibility = ["//visibility:public"])

${build}""",
    sha256 = "${archive.sha256}",
    url = "${archive.url}",
)`
  })
  return { source, text: `${blocks.join('\n\n')}\n` }
}
